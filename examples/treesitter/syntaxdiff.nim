## `examples/gitdiff.nim` with tree-sitter syntax highlighting laid over the
## diff — the two are different axes on the same bytes, and the point of this
## variant is making them compose.
##
## **The added idea: syntax colour is a foreground, a diff is a background, and
## one line has to carry both.** tree-sitter hands back, per line, a set of
## non-overlapping byte spans each naming a capture (`@keyword`, `@string`, …)
## that a theme turns into a *foreground*. The diff already wants the same bytes
## for something orthogonal: a faint *background* tint saying "this line
## changed", and a stronger tint on the runes the intra-line pass flagged.
## Neither span set refines the other — their edges fall in different places —
## so `mergedSpans`_ splices the line at the union of every syntax edge and
## every changed-range edge and gives each segment one foreground (the capture
## covering it) and one background (`style.merge` lays the tint on without
## touching the capture's colour). `c` drops the syntax layer, leaving exactly
## what `gitdiff` renders.
##
## Two consequences of the merge that shape the rest:
##
## * **The palette is background-only now.** `gitdiff`'s foreground-only fallback
##   for a terminal that will not answer `OSC 11` would fight the syntax colours,
##   so this one always mixes its tints from a ground — the real background when
##   the terminal gives one, a dark stand-in when it does not. The diff speaks in
##   the background so the grammar can have the foreground.
## * **Highlighting needs the whole file, not the hunk.** A fragment parses into
##   `ERROR` nodes and comes back confidently wrong (see
##   `examples/treesitter/snippets.nim`), so `hlCmd`_ pulls both full blobs for
##   the selected file out of git — `git show` for the old side, the work tree
##   or the index for the new — and the hunk's own line numbers index into them.
##   It is a generation-guarded load beside the diff load, the same shape
##   `gitlog` uses for `git show`.
##
## Everything else is `gitdiff`: `w` toggles the intra-line pass, `b` folds to
## unified, `s` cycles working-tree / staged / since-HEAD, `tab` moves between
## the file list and the diff, the wheel scrolls whichever pane the pointer is
## over (`poMouseClicks`, `gitlog`'s `regions` / `contains` block), `enter` hands
## off to `git diff`'s own pager. Same
## corners cut — removed lines pair with added lines by position, paths with
## spaces are not unquoted — plus one more: no grammar for `.nim`, so this repo's
## own diffs render through the plain fallback.
##
##   nimble snippets            # builds everything under examples/treesitter/
##   ./bin/syntaxdiff [path]
##   ./bin/syntaxdiff --selftest

import std/[os, osproc, streams, strutils, strformat, unicode, sequtils, algorithm]
import nimtui
import treesitter
import treesitter/langs/all
import treesitter/adapters/tui

const
  MaxDiffFiles = 400
  StatusHold = initDuration(seconds = 4)
  LnW = 4                 ## columns for a line number in a gutter
  MinSxs = 72             ## diff text narrower than this drops to unified
  NarrowAt = 100          ## terminal narrower than this hides the file list

type
  DiffSource = enum
    dsWorking = "working tree"
    dsStaged  = "staged"
    dsHead    = "since HEAD"

  LineKind = enum lkContext, lkDel, lkAdd

  RawLine = object
    kind: LineKind
    text: string

  Hunk = object
    oldStart, newStart: int
    header: string                 ## the `@@ … @@ section` line, verbatim
    lines: seq[RawLine]

  DiffFile = object
    path: string                   ## new path, or old path for a deletion
    oldPath: string
    status: string                 ## "", "new", "deleted", "renamed", "binary"
    hunks: seq[Hunk]
    added, removed: int

  RowKind = enum rkHunk, rkContext, rkChange, rkDel, rkAdd

  Row = object
    ## One visual row of the aligned diff. A `rkChange` carries both sides and
    ## the token flags from the intra-line pass; the line-only kinds fill one
    ## side and leave the other blank.
    kind: RowKind
    oldNo, newNo: int              ## 0 means "no number on this side"
    lToks, rToks: seq[string]
    lEmph, rEmph: seq[bool]
    text: string                   ## rkHunk only

  Pane = enum
    pFiles = "files"
    pDiff  = "diff"

  # --- messages --------------------------------------------------------------

  RootMsg = ref object of Msg
    root: string

  DiffLoadedMsg = ref object of Msg
    gen: int                       ## which load this belongs to
    files: seq[DiffFile]

  HlLoadedMsg = ref object of Msg
    ## The two full blobs for one file, parsed. The `Tree` is dropped — it is
    ## not copyable and the model is a value — so only the per-line spans and
    ## the resolved styles survive.
    gen: int
    idx: int                       ## which file in `files`
    oldSrc, newSrc: string
    oldHl, newHl: Highlights
    oldStyles, newStyles: seq[Style]
    oldLang, newLang: bool         ## a grammar was found for that side

  ClearStatusMsg = ref object of Msg

  Model = object
    root: string
    source: DiffSource
    files: seq[DiffFile]
    list: ListView
    diff: TextArea
    focus: Pane
    wordLevel: bool
    sideBySide: bool
    syntax: bool                   ## highlighting on (`c`)
    help: bool
    loading: bool
    gen: int
    status: string
    statusIsError: bool
    size: TermSize
    theme: Theme
    bg: Color
    addStyle, delStyle, addEmphStyle, delEmphStyle: Style
    hunkStyle, fillerStyle, paneStyle, gutterStyle: Style
    # --- the highlight of the currently selected file --------------------------
    hlIdx: int                     ## file index the fields below belong to, -1 = none
    hlGen: int
    oldSrc, newSrc: string
    oldHl, newHl: Highlights
    oldStyles, newStyles: seq[Style]
    oldLang, newLang: bool

# --- parsing a unified diff -------------------------------------------------

proc hunkBounds(s: string): tuple[o, n: int] =
  ## `@@ -o,c +n,c @@` → the two starting line numbers.
  proc numAt(str: string, at: int): int =
    var j = at
    while j < str.len and str[j] in {'0'..'9'}:
      result = result * 10 + (str[j].ord - '0'.ord)
      inc j
  let dash = s.find('-')
  let plus = s.find('+', dash + 1)
  if dash >= 0: result.o = numAt(s, dash + 1)
  if plus >= 0: result.n = numAt(s, plus + 1)

proc parseDiff(output: string): seq[DiffFile] =
  ## The boundary everything downstream rests on. The `--- ` / `+++ ` file lines
  ## are trusted for the paths ahead of the `diff --git` line, since a body line
  ## can begin `--- ` too — hence the `inHunk` guard on those two branches.
  var
    cur: DiffFile
    have = false
    inHunk = false
  for line in output.splitLines:
    if line.startsWith("diff --git "):
      if have: result.add cur
      if result.len >= MaxDiffFiles: return
      cur = DiffFile()
      have = true
      inHunk = false
      let rest = line["diff --git ".len .. ^1]
      if rest.startsWith("a/"):
        let sep = rest.find(" b/")
        if sep > 0:
          cur.oldPath = rest[2 ..< sep]
          cur.path = rest[sep + 3 .. ^1]
    elif not have:
      continue
    elif line.startsWith("new file"): cur.status = "new"
    elif line.startsWith("deleted file"): cur.status = "deleted"
    elif line.startsWith("rename from "):
      cur.oldPath = line["rename from ".len .. ^1]
    elif line.startsWith("rename to "):
      cur.path = line["rename to ".len .. ^1]
      cur.status = "renamed"
    elif line.startsWith("Binary files "): cur.status = "binary"
    elif not inHunk and line.startsWith("--- "):
      let p = line[4 .. ^1]
      if p != "/dev/null": cur.oldPath = (if p.startsWith("a/"): p[2 .. ^1] else: p)
    elif not inHunk and line.startsWith("+++ "):
      let p = line[4 .. ^1]
      if p != "/dev/null": cur.path = (if p.startsWith("b/"): p[2 .. ^1] else: p)
    elif line.startsWith("@@ -"):
      let (o, n) = hunkBounds(line)
      cur.hunks.add Hunk(oldStart: o, newStart: n, header: line)
      inHunk = true
    elif inHunk and line.len > 0 and line[0] in {' ', '+', '-'}:
      let k = case line[0]
              of '+': lkAdd
              of '-': lkDel
              else: lkContext
      if k == lkAdd: inc cur.added
      elif k == lkDel: inc cur.removed
      cur.hunks[^1].lines.add RawLine(kind: k, text: line[1 .. ^1])
    else: discard
  if have: result.add cur

# --- the two alignments ----------------------------------------------------

proc classOf(r: Rune): int =
  ## Token classes: whitespace, word (letters and digits), everything else.
  let c = int(r)
  if c == 0x20 or c == 0x09: 0
  elif (c >= ord('0') and c <= ord('9')) or r.isAlpha: 1
  else: 2

proc tokenize(s: string): seq[string] =
  ## Maximal runs of one class. Grouping punctuation runs rather than splitting
  ## each character keeps the highlight from freckling a line of `))));`.
  var
    cur = ""
    curClass = -1
  for r in s.runes:
    let c = classOf(r)
    if c != curClass and cur.len > 0:
      result.add cur
      cur = ""
    curClass = c
    cur.add $r
  if cur.len > 0: result.add cur

proc changed(x, y: seq[string]): tuple[a, b: seq[bool]] =
  ## Longest common subsequence over two token sequences; the flags mark every
  ## token not on the common path. This is the intra-line pass, and it is the
  ## same walk `buildRows`_ does over whole lines one level up.
  let n = x.len
  let m = y.len
  var dp = newSeq[seq[int]](n + 1)
  for i in 0 .. n: dp[i] = newSeq[int](m + 1)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      dp[i][j] =
        if x[i] == y[j]: dp[i + 1][j + 1] + 1
        else: max(dp[i + 1][j], dp[i][j + 1])
  result.a = newSeq[bool](n)
  result.b = newSeq[bool](m)
  var i, j = 0
  while i < n and j < m:
    if x[i] == y[j]: inc i; inc j
    elif dp[i + 1][j] >= dp[i][j + 1]: result.a[i] = true; inc i
    else: result.b[j] = true; inc j
  while i < n: result.a[i] = true; inc i
  while j < m: result.b[j] = true; inc j

proc emit(rows: var seq[Row], dels, adds: seq[string],
          oldNo, newNo: var int, wordLevel: bool) =
  ## Flush one block of removed lines against one block of added lines: pair them
  ## by position, run the token pass on each pair, and spill the remainder as
  ## one-sided rows.
  let pairs = min(dels.len, adds.len)
  for i in 0 ..< pairs:
    var row = Row(kind: rkChange, oldNo: oldNo, newNo: newNo)
    if wordLevel:
      let dt = tokenize(dels[i])
      let at = tokenize(adds[i])
      let c = changed(dt, at)
      row.lToks = dt; row.lEmph = c.a
      row.rToks = at; row.rEmph = c.b
    else:
      row.lToks = @[dels[i]]; row.lEmph = @[true]
      row.rToks = @[adds[i]]; row.rEmph = @[true]
    rows.add row
    inc oldNo; inc newNo
  for i in pairs ..< dels.len:
    rows.add Row(kind: rkDel, oldNo: oldNo, lToks: @[dels[i]], lEmph: @[false])
    inc oldNo
  for i in pairs ..< adds.len:
    rows.add Row(kind: rkAdd, newNo: newNo, rToks: @[adds[i]], rEmph: @[false])
    inc newNo

proc buildRows(f: DiffFile, wordLevel: bool): seq[Row] =
  for h in f.hunks:
    result.add Row(kind: rkHunk, text: h.header)
    var
      oldNo = h.oldStart
      newNo = h.newStart
      dels, adds: seq[string]
    for ln in h.lines:
      case ln.kind
      of lkContext:
        emit(result, dels, adds, oldNo, newNo, wordLevel)
        dels.setLen 0
        adds.setLen 0
        result.add Row(kind: rkContext, oldNo: oldNo, newNo: newNo,
                       lToks: @[ln.text], rToks: @[ln.text])
        inc oldNo; inc newNo
      of lkDel: dels.add ln.text
      of lkAdd: adds.add ln.text
    emit(result, dels, adds, oldNo, newNo, wordLevel)

# --- the palette, from the terminal's own background ----------------------

proc applyBackground(m: var Model, bg: Color) =
  ## Every style here is a *background* — the changed-line tint, the stronger
  ## tint on the runes the intra-line pass flagged, the pane fill — because the
  ## foreground now belongs to the grammar. `gitdiff`'s foreground-only fallback
  ## for `ckDefault` is gone: it would fight the syntax colours, so instead the
  ## tints are always mixed from a ground — the real background when the terminal
  ## answered `OSC 11`, a dark stand-in when it did not. `addEmphStyle` no longer
  ## brightens the text to `t.fg` for the same reason: `mergedSpans` keeps
  ## whatever colour the capture put there.
  m.bg = bg
  let dark = bg.kind == ckDefault or bg.luminance < 0.5
  m.theme = derive(hex"#5ad1c0", dark = dark)
  let
    t = m.theme
    ground = if bg.kind != ckDefault: bg
             elif dark: hex"#161616" else: hex"#f4f4f4"
  m.addStyle = Style().bg(lerp(ground, t.success, 0.16))
  m.delStyle = Style().bg(lerp(ground, t.error, 0.16))
  m.addEmphStyle = Style().bg(lerp(ground, t.success, 0.40))
  m.delEmphStyle = Style().bg(lerp(ground, t.error, 0.40))
  m.hunkStyle = Style().fg(t.info).bg(lerp(ground, t.info, 0.10))
  m.fillerStyle = Style().bg(lerp(ground, t.muted, 0.10))
  m.paneStyle = Style().bg(lerp(ground, t.accent, 0.05))
  m.gutterStyle = Style().fg(t.border).bg(lerp(ground, t.accent, 0.05))
  m.diff.lineStyle = m.paneStyle
  m.diff.scrollbarStyle = m.theme.mutedStyle

# --- geometry -------------------------------------------------------------

type
  Rect = object
    x, y, w, h: int              ## 1-based, to match what a `MouseMsg` carries
  Regions = object
    files, diff: Rect

proc contains(r: Rect, x, y: int): bool =
  r.w > 0 and r.h > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

proc inner(r: Rect): Rect =
  Rect(x: r.x + 1, y: r.y + 1, w: max(r.w - 2, 0), h: max(r.h - 2, 0))

const
  HeaderRows = 2
  FooterRows = 1

proc regions(m: Model): Regions =
  let
    bodyTop = HeaderRows + 1
    bodyH = max(m.size.height - HeaderRows - FooterRows, 3)
  if m.size.width < NarrowAt:
    result.diff = Rect(x: 1, y: bodyTop, w: m.size.width, h: bodyH)
  else:
    let listW = clamp(m.size.width div 4, 24, 44)
    result.files = Rect(x: 1, y: bodyTop, w: listW, h: bodyH)
    result.diff = Rect(x: listW + 1, y: bodyTop, w: m.size.width - listW, h: bodyH)

# --- the span merge ----------------------------------------------------

type Rng = tuple[a, b: int]        ## a half-open byte range [a, b) into a source

proc selIdx(m: Model): int =
  if m.files.len == 0: -1 else: min(m.list.cursor, m.files.high)

proc hlReady(m: Model, side: int): bool =
  ## The cached highlight belongs to the selected file and has a grammar for
  ## this side. `side` is 0 for the old text, 1 for the new.
  m.syntax and m.hlIdx == m.selIdx and
  (if side == 0: m.oldLang else: m.newLang)

proc rangesFromToks(offset: int, toks: seq[string], emph: seq[bool]): seq[Rng] =
  ## The intra-line pass' flagged tokens as byte ranges into the source line,
  ## adjacent ones fused. `toks` concatenates to the line, so the offsets add up.
  var p = offset
  for k in 0 ..< toks.len:
    let n = toks[k].len
    if k < emph.len and emph[k]:
      if result.len > 0 and result[^1].b == p: result[^1].b = p + n
      else: result.add (p, p + n)
    p += n

proc mergedSpans(src: string, spans: seq[treesitter.Span], r: Slice[int],
                 styles: seq[Style], base, emph: Style,
                 changed: seq[Rng]): Spans =
  ## One source line, spliced at the union of the syntax-span edges and the
  ## changed-range edges. Each segment lands wholly inside or wholly outside
  ## every span and every range, so one lookup fixes its foreground (the capture
  ## covering it, else none) and `style.merge` lays the background tint on
  ## without disturbing it — emphasis where the segment is in a changed range,
  ## the line tint elsewhere.
  if r.b < r.a: return
  let lo = r.a
  let hi = r.b + 1
  var cuts = @[lo, hi]
  for sp in spans:
    if sp.startByte > lo and sp.startByte < hi: cuts.add sp.startByte
    if sp.endByte  > lo and sp.endByte  < hi: cuts.add sp.endByte
  for c in changed:
    if c.a > lo and c.a < hi: cuts.add c.a
    if c.b > lo and c.b < hi: cuts.add c.b
  cuts.sort
  for i in 0 ..< cuts.len - 1:
    let a = cuts[i]
    let b = cuts[i + 1]
    if a >= b: continue
    var st = Style()
    for sp in spans:
      if sp.startByte <= a and sp.endByte >= b:
        if sp.capture >= 0 and sp.capture < styles.len: st = styles[sp.capture]
        break
    var ch = false
    for c in changed:
      if c.a <= a and c.b >= b: ch = true; break
    result.add(src[a ..< b], merge(st, (if ch: emph else: base)))

# --- rendering the diff into lines --------------------------------------

proc box(s: Spans, width: int, base: Style): string =
  ## A span line to exactly `width`: elided with a marker if long, padded in the
  ## base style if short, so the changed-line tint reaches the pane edge.
  (if s.displayWidth > width: s.elide(width, "…", base)
   else: s.pad(width, base)).render()

proc gutter(a, b: int): string =
  (if a > 0: align($a, LnW) else: spaces(LnW)) & " " &
  (if b > 0: align($b, LnW) else: spaces(LnW))

proc codeRun(m: Model, side: int, toks: seq[string], emph: seq[bool],
             no: int, base, emphS: Style): Spans =
  ## The code part of a cell — highlighted and tinted if a grammar is ready for
  ## this side, otherwise the plain token walk `gitdiff` does, which
  ## `mergedSpans` with no spans reproduces exactly.
  if no > 0 and m.hlReady(side):
    let (src, hl, sty) =
      if side == 0: (m.oldSrc, m.oldHl, m.oldStyles)
      else: (m.newSrc, m.newHl, m.newStyles)
    if no - 1 < hl.lineRanges.len:
      return mergedSpans(src, hl.lines[no - 1], hl.lineRanges[no - 1], sty,
                         base, emphS,
                         rangesFromToks(hl.lineRanges[no - 1].a, toks, emph))
  for i in 0 ..< toks.len:
    result.add(toks[i], (if i < emph.len and emph[i]: emphS else: base))

proc cell(m: Model, side: int, toks: seq[string], emph: seq[bool], no: int,
          base, emphS, noS: Style): Spans =
  result.add((if no > 0: align($no, LnW) else: spaces(LnW)) & " ", noS)
  result.add m.codeRun(side, toks, emph, no, base, emphS)

proc metaLine(m: Model, f: DiffFile, w: int): string =
  let t = m.theme
  var s: Spans
  s.add("▸ ", t.accentStyle)
  s.add((if f.oldPath.len > 0 and f.oldPath != f.path: f.oldPath & " → " & f.path
         else: f.path), t.secondaryStyle.bold())
  if f.status.len > 0: s.add("  [" & f.status & "]", t.warnStyle)
  s.add("  +" & $f.added, t.successStyle)
  s.add("  −" & $f.removed, t.errorStyle)
  s.fit(w).render()

proc sxsLine(m: Model, row: Row, lw, rw: int): string =
  let t = m.theme
  if row.kind == rkHunk:
    let full = lw + 1 + rw
    return m.hunkStyle.renderOver(
      padVisible(truncateVisible(oneLine(row.text), full), full))
  let lBase = case row.kind
    of rkChange, rkDel: m.delStyle
    of rkContext: m.paneStyle
    else: m.fillerStyle
  let rBase = case row.kind
    of rkChange, rkAdd: m.addStyle
    of rkContext: m.paneStyle
    else: m.fillerStyle
  let l = box(m.cell(0, row.lToks, row.lEmph, row.oldNo, lBase, m.delEmphStyle,
                     lBase.fg(t.muted)), lw, lBase)
  let r = box(m.cell(1, row.rToks, row.rEmph, row.newNo, rBase, m.addEmphStyle,
                     rBase.fg(t.muted)), rw, rBase)
  l & m.gutterStyle.render("│") & r

proc uniHalf(m: Model, side: int, sign: string, a, b: int, toks: seq[string],
             emph: seq[bool], base, emphS: Style, w: int): string =
  var s: Spans
  s.add(gutter(a, b) & " ", base.fg(m.theme.muted))
  s.add(sign, base)
  s.add m.codeRun(side, toks, emph, (if side == 0: a else: b), base, emphS)
  # Padded, never truncated: a unified line keeps its full length so `←` / `→`
  # have something off-screen to scroll to.
  s.pad(w, base).render()

proc uniLines(m: Model, row: Row, w: int): seq[string] =
  case row.kind
  of rkHunk:
    @[m.hunkStyle.renderOver(padVisible(truncateVisible(oneLine(row.text), w), w))]
  of rkContext:
    var s: Spans
    s.add(gutter(row.oldNo, row.newNo) & "   ", m.paneStyle.fg(m.theme.muted))
    s.add m.codeRun(1, row.rToks, row.rEmph, row.newNo, m.paneStyle, m.paneStyle)
    @[s.pad(w, m.paneStyle).render()]
  of rkChange:
    @[uniHalf(m, 0, "- ", row.oldNo, 0, row.lToks, row.lEmph,
              m.delStyle, m.delEmphStyle, w),
      uniHalf(m, 1, "+ ", 0, row.newNo, row.rToks, row.rEmph,
              m.addStyle, m.addEmphStyle, w)]
  of rkDel:
    @[uniHalf(m, 0, "- ", row.oldNo, 0, row.lToks, row.lEmph,
              m.delStyle, m.delEmphStyle, w)]
  of rkAdd:
    @[uniHalf(m, 1, "+ ", 0, row.newNo, row.rToks, row.rEmph,
              m.addStyle, m.addEmphStyle, w)]

proc rebuildDiff(m: var Model) =
  ## The selected file, turned into the lines the `TextArea` scrolls. Rebuilt
  ## whenever the selection, the source, the width or a display toggle changes —
  ## it is all in memory, so there is no reason to debounce it the way `gitlog`
  ## debounces a `git show`.
  if m.size.width == 0 or m.size.height == 0: return
  m.diff.xOffset = 0
  let w = max(m.diff.textWidth, 1)
  var lines: seq[string]
  if m.files.len == 0:
    lines = @["", "  no changes — " & $m.source & " is clean"]
  else:
    let f = m.files[min(m.list.cursor, m.files.high)]
    lines.add m.metaLine(f, w)
    lines.add ""
    if f.status == "binary":
      lines.add "  binary file — no textual diff"
    elif f.hunks.len == 0:
      lines.add "  no textual changes (mode or rename only)"
    else:
      let rows = buildRows(f, m.wordLevel)
      if m.sideBySide and w >= MinSxs:
        let lw = (w - 1) div 2
        let rw = w - 1 - lw
        for row in rows: lines.add m.sxsLine(row, lw, rw)
      else:
        for row in rows:
          for ln in m.uniLines(row, w): lines.add ln
  m.diff.setLines(lines)
  m.diff.scrollTo 0

# --- talking to git ----------------------------------------------------------

proc git(root: string, args: openArray[string]): string =
  ## Run git in `root`, return stdout, raise on non-zero exit.
  ##
  ## Called only from inside a `Cmd`, so the raise is right: the runtime turns it
  ## into an `ErrorMsg` on the status line rather than unwinding the loop with
  ## the terminal in raw mode. `--no-pager` because the output here is a pipe we
  ## are about to read — `openInPager`_ is the other direction and omits it.
  var p = startProcess("git", workingDir = root,
                       args = @["--no-pager"] & @args, options = {poUsePath})
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    let err = p.errorStream.readAll().strip
    raise newException(IOError, "git " & args.join(" ") & " exited " & $code &
      (if err.len > 0: ": " & err.splitLines[0] else: ""))
  output

proc diffArgs(s: DiffSource, colour: bool): seq[string] =
  result = @["diff", if colour: "--color=always" else: "--no-color"]
  case s
  of dsWorking: discard
  of dsStaged: result.add "--cached"
  of dsHead: result.add "HEAD"

proc rootCmd(path: string): Cmd =
  result = proc (): Msg =
    RootMsg(root: git(path, ["rev-parse", "--show-toplevel"]).strip)

proc diffCmd(root: string, s: DiffSource, gen: int): Cmd =
  result = proc (): Msg =
    DiffLoadedMsg(gen: gen, files: parseDiff(git(root, diffArgs(s, false))))

# --- fetching and highlighting the two full blobs --------------------------

proc showBlob(root, rev, path: string): string =
  ## `git show <rev>:<path>`, "" when the path is not there at that rev — which
  ## is the normal answer for the old side of a new file. `rev` is "" for the
  ## index (`git show :path`).
  try: git(root, ["show", rev & ":" & path])
  except CatchableError: ""

proc sidesFor(root: string, s: DiffSource, f: DiffFile): (string, string) =
  ## The exact two versions git diffed, so the hunk line numbers land: index vs
  ## work tree for `dsWorking`, HEAD vs index for `dsStaged`, HEAD vs work tree
  ## for `dsHead`.
  var o, n = ""
  let oldP = (if f.oldPath.len > 0: f.oldPath else: f.path)
  if f.status != "new":
    o = showBlob(root, (if s == dsWorking: "" else: "HEAD"), oldP)
  if f.status != "deleted":
    case s
    of dsWorking, dsHead:
      let p = root / f.path
      n = (try: (if fileExists(p): readFile(p) else: "") except CatchableError: "")
    of dsStaged:
      n = showBlob(root, "", f.path)
  (o, n)

proc highlightInto(msg: HlLoadedMsg, path, src: string, isOld: bool) =
  if src.len == 0: return
  let lang = detectLanguage(path = path, source = src)
  if lang == nil: return
  let h = newHighlighter(lang).highlight(src)
  let sty = defaultSyntaxStyles().compile(h.captureNames)
  if isOld: (msg.oldHl = h; msg.oldStyles = sty; msg.oldLang = true)
  else:     (msg.newHl = h; msg.newStyles = sty; msg.newLang = true)

proc hlCmd(root: string, s: DiffSource, f: DiffFile, idx, gen: int): Cmd =
  ## Runs in a `Cmd`, so the `git show` subprocesses and the parse are off the
  ## render path; a raise becomes an `ErrorMsg` like any other.
  result = proc (): Msg =
    let m = HlLoadedMsg(gen: gen, idx: idx)
    if f.status == "binary": return m
    (m.oldSrc, m.newSrc) = sidesFor(root, s, f)
    m.highlightInto((if f.oldPath.len > 0: f.oldPath else: f.path), m.oldSrc, true)
    m.highlightInto(f.path, m.newSrc, false)
    m

# --- update -------------------------------------------------------------

proc relayout(m: var Model) =
  let r = m.regions
  m.list.vp.height = max(r.files.inner.h, 1)
  m.list.sync m.files.len
  m.diff.resize(max(r.diff.inner.w, 1), max(r.diff.inner.h, 1))
  if r.files.w == 0: m.focus = pDiff   # nothing to focus when the list is gone
  m.rebuildDiff()

proc setStatus(m: var Model, s: string, isError = false): Cmd =
  m.status = s
  m.statusIsError = isError
  after(StatusHold, ClearStatusMsg())

proc reload(m: var Model): Cmd =
  m.gen.inc
  m.loading = true
  m.hlIdx = -1                      # the file indices are about to mean new files
  diffCmd(m.root, m.source, m.gen)

proc ensureHl(m: var Model): Cmd =
  ## Fetch and highlight the selected file unless it is already the cached one.
  ## Fired on every selection change; the generation guard drops all but the
  ## last when the cursor moves quickly, and a slow `git show` stays off the
  ## render path because this returns a `Cmd`.
  let i = m.selIdx
  if not m.syntax or i < 0 or i == m.hlIdx: return nil
  m.hlGen.inc
  hlCmd(m.root, m.source, m.files[i], i, m.hlGen)

proc nextSource(s: DiffSource): DiffSource =
  case s
  of dsWorking: dsStaged
  of dsStaged: dsHead
  of dsHead: dsWorking

proc openInPager(m: Model): Cmd =
  ## `git diff` with the terminal handed to it, git's own colours and git's own
  ## pager — a full screen of scrollable diff for no code, the way `gitlog`'s
  ## `enter` does it. The runtime restores the terminal, waits, and takes it
  ## back.
  execCmd("git", @["-C", m.root] & diffArgs(m.source, true),
          proc (res: ExecResult): Msg =
            if res.error != nil: ErrorMsg(error: res.error) else: nil)

proc onMouse(m: var Model, e: MouseMsg): Cmd =
  ## The wheel only, routed to whichever pane the pointer is over — the same
  ## `regions` / `contains` block `gitlog` uses. `poMouseClicks` is the tracking
  ## level for it, since xterm reports the wheel as a button press at every level
  ## and asking for motion would only add reports to ignore.
  if e.button notin {mbWheelUp, mbWheelDown}: return nil
  let
    r = m.regions
    up = e.button == mbWheelUp
  if r.diff.contains(e.x, e.y):
    m.diff.scrollBy(if up: -3 else: 3)
  elif r.files.contains(e.x, e.y):
    # One file per notch — a list is short and a jump of three skips past what
    # the pointer is aimed at.
    m.list.moveBy(if up: -1 else: 1, m.files.len)
    m.rebuildDiff()
    return m.ensureHl()
  nil

proc onKey(m: var Model, k: KeyMsg): Cmd =
  ## Three levels, in the order they have to be tried — the same shape as
  ## `gitlog`, without the modal filter it does not have: the overlay, then the
  ## focused pane, then the application. `handleKey` returning false is what lets
  ## `q` reach the bottom level without either pane knowing what the other binds.

  # 1 — the overlay.
  if m.help:
    m.help = false
    return nil

  # 2 — the focused pane. `j` / `k` and the page keys go to whichever has focus.
  case m.focus
  of pFiles:
    if m.list.handleKey(k, m.files.len):
      m.rebuildDiff()
      return m.ensureHl()
  of pDiff:
    if m.diff.handleKey(k): return nil

  # 3 — the application.
  if k.matches("q", "ctrl+c"): return quitCmd()
  elif k.matches("ctrl+z"): return suspendCmd()
  elif k.matches("tab"):
    # Only where there is a file list to move to; narrow drops it.
    if m.regions.files.w > 0:
      m.focus = if m.focus == pFiles: pDiff else: pFiles
  elif k.matches("?"): m.help = true
  elif k.matches("["):
    m.list.moveBy(-1, m.files.len)
    m.rebuildDiff()
    return m.ensureHl()
  elif k.matches("]"):
    m.list.moveBy(1, m.files.len)
    m.rebuildDiff()
    return m.ensureHl()
  elif k.matches("s"):
    m.source = nextSource(m.source)
    return m.reload()
  elif k.matches("r"):
    return m.reload()
  elif k.matches("w"):
    m.wordLevel = not m.wordLevel
    m.rebuildDiff()
  elif k.matches("b"):
    m.sideBySide = not m.sideBySide
    m.rebuildDiff()
  elif k.matches("c"):
    m.syntax = not m.syntax
    m.rebuildDiff()
    return m.ensureHl()
  elif k.matches("enter", "o"):
    return m.openInPager()
  nil

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of TerminalBgMsg:
    result[0].applyBackground TerminalBgMsg(msg).color
    result[0].rebuildDiff()

  elif result[0].size.handleResize(msg):
    result[0].relayout()

  elif msg of RootMsg:
    result[0].root = RootMsg(msg).root
    result[1] = diffCmd(result[0].root, m.source, m.gen)

  elif msg of DiffLoadedMsg:
    let d = DiffLoadedMsg(msg)
    if d.gen != m.gen: return
    result[0].files = d.files
    result[0].loading = false
    result[0].hlIdx = -1
    result[0].list.sync d.files.len
    if result[0].list.cursor > max(d.files.high, 0):
      result[0].list.moveTo(max(d.files.high, 0), d.files.len)
    result[0].rebuildDiff()
    result[1] = result[0].ensureHl()

  elif msg of HlLoadedMsg:
    let h = HlLoadedMsg(msg)
    if h.gen != m.hlGen: return
    result[0].hlIdx = h.idx
    result[0].oldSrc = h.oldSrc;       result[0].newSrc = h.newSrc
    result[0].oldHl = h.oldHl;         result[0].newHl = h.newHl
    result[0].oldStyles = h.oldStyles; result[0].newStyles = h.newStyles
    result[0].oldLang = h.oldLang;     result[0].newLang = h.newLang
    result[0].rebuildDiff()

  elif msg of ErrorMsg:
    result[0].loading = false
    result[1] = result[0].setStatus(
      ErrorMsg(msg).error.msg.splitLines[0], isError = true)

  elif msg of ClearStatusMsg:
    result[0].status = ""
    result[0].statusIsError = false

  elif msg of MouseMsg:
    result[1] = result[0].onMouse(MouseMsg(msg))

  elif msg of KeyMsg:
    result[1] = result[0].onKey(KeyMsg(msg))

# --- view --------------------------------------------------------------

proc header(m: Model): string =
  let t = m.theme
  let title = gradientText(" syntaxdiff", t.ramp, Style().bold())
  let where =
    if m.root.len == 0: t.mutedStyle.render(" opening…")
    else: "  " & t.accentStyle.render(m.root.lastPathPart)
  let count =
    if m.loading: t.mutedStyle.render("  …")
    elif m.files.len == 0: t.mutedStyle.render("  clean")
    else: t.mutedStyle.render("  " & $m.files.len & " files")
  let bar = statusBar(title & where & "  " &
                      t.secondaryStyle.render($m.source) & count, "", "",
                      m.size.width)
  let syntax =
    if not m.syntax: "syntax off"
    elif m.hlIdx == m.selIdx and (m.oldLang or m.newLang): "syntax on"
    elif m.hlIdx == m.selIdx: "syntax —"     # on, but no grammar for this file
    else: "syntax …"                         # on, still loading
  let legend = t.mutedStyle.render(
    " " & (if m.sideBySide: "side by side" else: "unified") & " · " &
    (if m.wordLevel: "word-diff on" else: "word-diff off") & " · " & syntax &
    " · bg " &
    (if m.bg.kind == ckDefault: "unknown"
     elif m.bg.luminance < 0.5: "dark" else: "light"))
  bar & "\n" & statusBar(legend, "", "", m.size.width)

proc footer(m: Model): string =
  let t = m.theme
  if m.status.len > 0:
    return " " & (if m.statusIsError: t.errorStyle.render("✗ " & m.status)
                  else: t.mutedStyle.render(m.status))
  " " & hints({"j/k": "scroll", "tab": "focus", "[/]": "file", "s": "source",
               "b": "layout", "w": "word-diff", "c": "syntax", "enter": "pager",
               "q": "quit"})

proc filesPanel(m: Model, r: Rect): string =
  let t = m.theme
  let inner = r.inner
  var items: seq[string]
  for f in m.files:
    let mark = case f.status
      of "new": t.successStyle.render("+")
      of "deleted": t.errorStyle.render("−")
      of "renamed": t.warnStyle.render("»")
      of "binary": t.mutedStyle.render("·")
      else: t.mutedStyle.render("~")
    var s: Spans
    s.add(mark & " ")
    s.add(elide(f.path, max(inner.w - 4, 6)))
    items.add s.render()
  let body =
    if m.files.len == 0: t.mutedStyle.render("  clean")
    else: m.list.render(items, inner.w, selectedStyle = t.selectionStyle)
  panel(RoundedBorder)
    .title(" files ")
    .footer(if m.files.len == 0: "" else: &" {m.list.cursor + 1}/{m.files.len} ")
    .styled(border = t.borderStyleFor(m.focus == pFiles),
            title = t.titleStyle, footer = t.mutedStyle)
    .render(body, r.w, r.h)

proc diffPanel(m: Model, r: Rect): string =
  let t = m.theme
  let f = if m.files.len > 0: m.files[min(m.list.cursor, m.files.high)]
          else: DiffFile()
  let title = if m.files.len == 0: " diff "
              else: " " & elide(f.path, max(r.w - 16, 8)) & " "
  panel(RoundedBorder)
    .title(title)
    .footer(" " & m.diff.positionLabel & " ")
    .styled(border = t.borderStyleFor(m.focus == pDiff),
            title = t.titleStyle, footer = t.mutedStyle)
    .render(m.diff.render(), r.w, r.h)

proc helpOverlay(m: Model): string =
  let t = m.theme
  const rows = [
    ("tab", "move focus between the file list and the diff"),
    ("j / k, ↑ ↓", "scroll the focused pane"),
    ("wheel", "scroll whichever pane the pointer is over"),
    ("ctrl+d / ctrl+u", "half a page"),
    ("g / G", "top / bottom"),
    ("← →", "scroll a long line sideways (diff, unified only)"),
    ("[ / ]", "previous / next file, without leaving the diff"),
    ("s", "cycle: working tree / staged / since HEAD"),
    ("b", "side by side or unified"),
    ("w", "intra-line (word) highlighting on / off"),
    ("c", "syntax highlighting on / off (needs a known language)"),
    ("enter, o", "open this diff in git's own pager"),
    ("r", "reload"),
    ("ctrl+z", "suspend"),
    ("q", "quit")]
  var body: seq[string]
  for (k, d) in rows:
    body.add "  " & t.accentStyle.render(padVisible(k, 16)) & " " &
             t.mutedStyle.render(d)
  panel(DoubleBorder)
    .title(" keys ")
    .pad(1)
    .shadow(t.mutedStyle)
    .styled(border = t.activeBorderStyle, title = t.titleStyle)
    .render(body.join("\n"), 66, body.len + 4)

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let r = m.regions
  let d = m.diffPanel(r.diff)
  let body = if r.files.w > 0: joinHorizontal([m.filesPanel(r.files), d]) else: d
  let frame = joinVertical(m.header, body, m.footer)
  if m.help: place(frame, m.helpOverlay) else: frame

# --- headless self-test ------------------------------------------------

const sample = """
diff --git a/src/foo.nim b/src/foo.nim
index 1111111..2222222 100644
--- a/src/foo.nim
+++ b/src/foo.nim
@@ -1,4 +1,4 @@ proc main() =
 import os
-let greeting = "hello world"
+let greeting = "hello there"
 echo greeting
 quit(0)
diff --git a/logo.png b/logo.png
new file mode 100644
index 0000000..3333333
Binary files /dev/null and b/logo.png differ
diff --git a/old.txt b/renamed.txt
similarity index 90%
rename from old.txt
rename to renamed.txt
index 4444444..5555555 100644
--- a/old.txt
+++ b/renamed.txt
@@ -1,2 +1,2 @@
-first line
+first LINE
 second line
"""

proc fixture(): Model =
  result = Model(root: "/tmp/repo", source: dsWorking, theme: DefaultTheme,
                 gen: 1, wordLevel: true, sideBySide: true, hlIdx: -1)
  result.list = initListView(height = 10, wrapAround = false)
  result.diff = initTextArea(width = 40, height = 12, wrap = false)
  result.size = TermSize(width: 150, height: 44)
  result.applyBackground(Color())
  result.files = parseDiff(sample)
  result.list.sync result.files.len

proc widthsOk(m: Model): bool =
  for line in m.diff.render().split('\n'):
    if displayWidth(line) != m.diff.width: return false
  true

const
  pyOld = "def f(x):\n    total = x\n    return total\n"
  pyNew = "def f(x, y=0):\n    total = x + y\n    return total\n"
  pySample = """
diff --git a/app.py b/app.py
index 1111111..2222222 100644
--- a/app.py
+++ b/app.py
@@ -1,3 +1,3 @@
-def f(x):
-    total = x
+def f(x, y=0):
+    total = x + y
     return total
"""

proc pyFixture(): Model =
  ## A one-file python diff with its two blobs already parsed, standing in for
  ## what `hlCmd` would have delivered — so the merge can be tested without a
  ## real repo to `git show` from.
  result = fixture()
  result.files = parseDiff(pySample)
  result.list.sync result.files.len
  result.syntax = true
  let lang = findLanguage("python")
  doAssert lang != nil, "the python grammar did not register"
  result.oldSrc = pyOld
  result.newSrc = pyNew
  result.oldHl = newHighlighter(lang).highlight(pyOld)
  result.newHl = newHighlighter(lang).highlight(pyNew)
  result.oldStyles = defaultSyntaxStyles().compile(result.oldHl.captureNames)
  result.newStyles = defaultSyntaxStyles().compile(result.newHl.captureNames)
  result.oldLang = true
  result.newLang = true
  result.hlIdx = 0

proc selfTest() =
  # Parsing — the boundary everything rests on.
  let files = parseDiff(sample)
  doAssert files.len == 3, $files.len
  doAssert files[0].path == "src/foo.nim"
  doAssert files[0].added == 1 and files[0].removed == 1
  doAssert files[0].hunks.len == 1
  doAssert files[1].status == "binary" and files[1].path == "logo.png"
  doAssert files[2].status == "renamed"
  doAssert files[2].oldPath == "old.txt" and files[2].path == "renamed.txt"
  echo "ok — a unified diff parses into files, hunks and per-file counts"

  # Alignment: a hunk becomes aligned rows, a -/+ block becomes one change row.
  let rows = buildRows(files[0], true)
  doAssert rows.len == 5
  doAssert rows[0].kind == rkHunk
  doAssert rows[2].kind == rkChange
  doAssert rows[2].oldNo == 2 and rows[2].newNo == 2
  echo "ok — a hunk aligns into rows and a -/+ pair collapses to one"

  # The intra-line pass: only the word that moved is flagged.
  doAssert rows[2].lEmph.count(true) == 1, $rows[2].lToks
  doAssert rows[2].rEmph.count(true) == 1
  doAssert rows[2].lEmph[rows[2].lToks.find("world")]
  doAssert rows[2].rEmph[rows[2].rToks.find("there")]
  doAssert changed(tokenize("same here"), tokenize("same here")).a.count(true) == 0
  let plain = buildRows(files[0], false)
  doAssert plain[2].lToks.len == 1 and plain[2].lEmph == @[true]
  echo "ok — the token pass narrows a change to the runes that moved"

  # Every rendered line is exactly the pane width, in both layouts and when the
  # file list has folded away — the assertion that catches an off-by-one before
  # it desynchronises the renderer.
  var m = fixture()
  m.relayout()
  doAssert m.diff.width > MinSxs
  doAssert widthsOk(m), "side by side"
  m.sideBySide = false
  m.rebuildDiff()
  doAssert widthsOk(m), "unified"
  for i in 0 ..< m.files.len:
    m.list.moveTo(i, m.files.len)
    m.rebuildDiff()
    doAssert widthsOk(m), "file " & $i
  var n = fixture()
  n.size = TermSize(width: 74, height: 30)
  n.relayout()
  doAssert n.regions.files.w == 0, "the file list folds away when narrow"
  doAssert widthsOk(n)
  echo "ok — every diff line is exactly the pane width, both layouts, any width"

  # The generation guard: a load from a superseded source switch is dropped.
  var g = fixture()
  g.gen = 7
  let (g2, _) = update(g, DiffLoadedMsg(gen: 6, files: @[]))
  doAssert g2.files.len == 3, "a stale load must not replace the file list"
  let (g3, _) = update(g, DiffLoadedMsg(gen: 7, files: parseDiff(sample)))
  doAssert g3.files.len == 3
  echo "ok — a diff load from a superseded generation is ignored"

  # `s` cycles the source and reloads; three steps return to the start.
  doAssert nextSource(nextSource(nextSource(dsWorking))) == dsWorking
  var s = fixture()
  let sc = s.onKey(KeyMsg(key: kRune, rune: "s".runeAt(0)))
  doAssert s.source == dsStaged and sc != nil
  echo "ok — s cycles the diff source and reloads"

  # Focus: `tab` moves between the panes, `j` drives whichever holds it, and a
  # folded-away file list leaves `tab` nowhere to go.
  var k = fixture()
  k.relayout()
  doAssert k.focus == pFiles
  discard k.onKey(KeyMsg(key: kTab))
  doAssert k.focus == pDiff
  let atCursor = k.list.cursor
  discard k.onKey(KeyMsg(key: kRune, rune: "j".runeAt(0)))
  doAssert k.list.cursor == atCursor, "j is the diff's while the diff has focus"
  discard k.onKey(KeyMsg(key: kTab))
  discard k.onKey(KeyMsg(key: kRune, rune: "j".runeAt(0)))
  doAssert k.list.cursor == atCursor + 1, "and the list's once focus is back"
  var kn = fixture()
  kn.size = TermSize(width: 74, height: 30)
  kn.relayout()
  doAssert kn.focus == pDiff, "a folded-away list cannot hold focus"
  discard kn.onKey(KeyMsg(key: kTab))
  doAssert kn.focus == pDiff, "and tab has nowhere to move it"
  echo "ok — tab moves focus, j/k follow it, and it copes when the list is gone"

  # The wheel scrolls whichever pane the pointer is over, picked by the same
  # rectangles the view draws into.
  var wh = fixture()
  wh.relayout()
  let wr = wh.regions
  discard wh.onMouse(MouseMsg(button: mbWheelDown, action: maPress,
                             x: wr.files.x, y: wr.files.inner.y))
  doAssert wh.list.cursor == 1, "the wheel over the file list moves the selection one file"
  wh.list.moveTo(0, wh.files.len)
  wh.rebuildDiff()
  discard wh.onMouse(MouseMsg(button: mbWheelUp, action: maPress,
                             x: wr.diff.x, y: wr.diff.inner.y))
  doAssert wh.list.cursor == 0, "the wheel over the diff leaves the selection alone"
  echo "ok — the wheel scrolls the pane under the pointer"

  # `enter` hands off to git's pager; under runHeadless no child runs, so `then`
  # is called with an error and the status line says so rather than hanging.
  # `maxTimers = 0`: headless timers fire immediately, so the `ClearStatusMsg`
  # that `setStatus` arms would otherwise wipe what is being asserted.
  var e = fixture()
  let final = newProgram(e, update, view).runHeadless(
    @[Msg(KeyMsg(key: kEnter))], maxTimers = 0)
  doAssert final.statusIsError and final.status.len > 0
  echo "ok — enter hands off to git's pager, and answers under runHeadless"

  # --- the span merge --------------------------------------------------------
  var p = pyFixture()
  p.relayout()
  doAssert p.diff.width > MinSxs
  doAssert widthsOk(p), "highlighted side by side stays exactly the pane width"
  p.sideBySide = false
  p.rebuildDiff()
  doAssert widthsOk(p), "highlighted unified too"
  p.wordLevel = false
  p.rebuildDiff()
  doAssert widthsOk(p), "and with the intra-line pass off"
  echo "ok — a highlighted diff line is still exactly the pane width"

  # A changed line's spans carry a capture foreground AND a diff-tint background,
  # spliced — the emphasis tint on the moved token, the line tint on the rest.
  p = pyFixture()
  let pyRows = buildRows(p.files[0], true)
  let chg = pyRows.filterIt(it.kind == rkChange)[0]
  let r = p.newHl.lineRanges[chg.newNo - 1]
  let sp = mergedSpans(p.newSrc, p.newHl.lines[chg.newNo - 1], r, p.newStyles,
                       p.addStyle, p.addEmphStyle,
                       rangesFromToks(r.a, chg.rToks, chg.rEmph))
  doAssert sp.items.anyIt(it.style.fgc.kind != ckDefault), "a capture fg survived"
  doAssert sp.items.anyIt(it.style.bgc == p.addStyle.bgc), "the line tint is there"
  doAssert sp.items.anyIt(it.style.bgc == p.addEmphStyle.bgc), "and the emphasis tint"

  # `c` off: the merge collapses to the plain token walk — no foregrounds beyond
  # what the tint carries (none), tints unchanged.
  let bare = mergedSpans(p.newSrc, @[], r, @[],
                         p.addStyle, p.addEmphStyle,
                         rangesFromToks(r.a, chg.rToks, chg.rEmph))
  doAssert not bare.items.anyIt(it.style.fgc.kind != ckDefault), "no fg with syntax off"
  doAssert bare.items.anyIt(it.style.bgc == p.addEmphStyle.bgc)
  echo "ok — one segment set carries a capture fg and a diff bg spliced together"

  # `hlReady` gates on the cached file matching the selection.
  p = pyFixture()
  doAssert p.hlReady(1)
  p.list.moveTo(0, p.files.len)     # still file 0 here, but flip the cache marker
  p.hlIdx = 5
  doAssert not p.hlReady(1), "a stale highlight is not used"
  echo "ok — the highlight is used only while it belongs to the selected file"

  echo "all good"

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--selftest":
    selfTest()
    quit(0)

  let path = if paramCount() > 0: paramStr(1).absolutePath else: getCurrentDir()
  var model = Model(theme: DefaultTheme, source: dsWorking, loading: true,
                    gen: 1, wordLevel: true, sideBySide: true,
                    syntax: true, hlIdx: -1)
  model.list = initListView(height = 10, wrapAround = false)
  model.diff = initTextArea(width = 40, height = 10, wrap = false)
  model.applyBackground(Color())        # until the terminal says otherwise

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor, poQueryBackground,
                                poMouseClicks},
                     initCmd = rootCmd(path)).run()
