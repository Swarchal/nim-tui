## A working-tree diff viewer: side by side, with the changes *within* each line
## picked out.
##
## **The one idea: a diff needs two comparisons a unified patch does not carry.**
## `git diff` hands you whole lines marked `+` or `-`; turning that into
## something a reader can follow needs two more passes, and neither is the shape
## of `wrapText` or `truncateVisible`:
##
## * **Alignment.** The removed lines put beside the added ones, so the eye pairs
##   an old line with its replacement instead of scanning a `-` block and then a
##   `+` block and holding both in its head.
## * **The intra-line diff.** Once a `-`/`+` pair is aligned, a *second* sequence
##   alignment — over tokens this time, not lines — says which runs of the line
##   actually moved, so a one-character edit lights up one word rather than
##   eighty columns of unchanged code.
##
## Both are the same O(n·m) longest-common-subsequence walk, run once over lines
## per hunk and once over tokens per changed pair. `w` turns the token pass off
## to show what it buys; `b` folds the two columns back into a unified view (still
## token-highlighted), which is also what happens automatically below ~72
## columns, where side by side has nothing left to give.
##
## Around that, the smaller decisions: `s` cycles what is being diffed — the
## working tree, the staged changes, everything since `HEAD`; the file list and
## the diff are two focusable panes with `tab` between them and `j` / `k` driving
## whichever has focus, exactly as `gitlog`'s commit list and diff work, with
## `[` / `]` also stepping through files without leaving the diff; `enter` hands
## the terminal to `git diff` in its own pager; and the palette is mixed from the
## terminal's real
## background exactly as `gitlog` does it, because a diff is the case that needs
## it — a changed-line tint a fifth of the way from the true background reads as
## a tint on either polarity, where a literal pair is wrong on half of all
## terminals.
##
## Deliberately simpler than it could be, and the two places that matters:
## consecutive removed lines are paired with added lines *by position* rather
## than by a third LCS over the block, and a path containing a space or a shell
## metacharacter is not unquoted. Both are fine for reading your own changes and
## would need doing for a general tool.
##
##   nim c -r --path:src examples/gitdiff.nim [path]
##   ./bin/gitdiff --selftest

import std/[os, osproc, streams, strutils, strformat, unicode, sequtils]
import nimtui

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
  ## Two backgrounds that say "this line changed" without a foreground of their
  ## own, plus a stronger pair for the tokens the intra-line pass flagged. There
  ## is no literal pair that works on both a near-black and a near-white
  ## terminal, so both are mixed from the background actually in use; `ckDefault`
  ## — the terminal declined — falls back to a foreground-only design, which is
  ## legible whatever it lands on.
  m.bg = bg
  if bg.kind == ckDefault:
    m.theme = DefaultTheme
    m.addStyle = Style().fg(m.theme.success)
    m.delStyle = Style().fg(m.theme.error)
    m.addEmphStyle = Style().fg(m.theme.success).bold().underline()
    m.delEmphStyle = Style().fg(m.theme.error).bold().underline()
    m.hunkStyle = Style().fg(m.theme.info)
    m.fillerStyle = Style().faint()
    m.paneStyle = Style()
    m.gutterStyle = m.theme.borderStyle
  else:
    let dark = bg.luminance < 0.5
    m.theme = derive(hex"#5ad1c0", dark = dark)
    let t = m.theme
    m.addStyle = Style().bg(lerp(bg, t.success, 0.16))
    m.delStyle = Style().bg(lerp(bg, t.error, 0.16))
    m.addEmphStyle = Style().bg(lerp(bg, t.success, 0.40)).fg(t.fg)
    m.delEmphStyle = Style().bg(lerp(bg, t.error, 0.40)).fg(t.fg)
    m.hunkStyle = Style().fg(t.info).bg(lerp(bg, t.info, 0.10))
    m.fillerStyle = Style().bg(lerp(bg, t.muted, 0.10))
    m.paneStyle = Style().bg(lerp(bg, t.accent, 0.05))
    m.gutterStyle = Style().fg(t.border).bg(lerp(bg, t.accent, 0.05))
  m.diff.lineStyle = m.paneStyle
  m.diff.scrollbarStyle = m.theme.mutedStyle

# --- geometry -------------------------------------------------------------

type
  Rect = object
    x, y, w, h: int
  Regions = object
    files, diff: Rect

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

# --- rendering the diff into lines --------------------------------------

proc box(s: Spans, width: int, base: Style): string =
  ## A span line to exactly `width`: elided with a marker if long, padded in the
  ## base style if short, so the changed-line tint reaches the pane edge.
  (if s.displayWidth > width: s.elide(width, "…", base)
   else: s.pad(width, base)).render()

proc gutter(a, b: int): string =
  (if a > 0: align($a, LnW) else: spaces(LnW)) & " " &
  (if b > 0: align($b, LnW) else: spaces(LnW))

proc cell(toks: seq[string], emph: seq[bool], no: int,
          base, emphS, noS: Style): Spans =
  result.add((if no > 0: align($no, LnW) else: spaces(LnW)) & " ", noS)
  for i in 0 ..< toks.len:
    result.add(toks[i], (if i < emph.len and emph[i]: emphS else: base))

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
  let l = box(cell(row.lToks, row.lEmph, row.oldNo, lBase, m.delEmphStyle,
                   lBase.fg(t.muted)), lw, lBase)
  let r = box(cell(row.rToks, row.rEmph, row.newNo, rBase, m.addEmphStyle,
                   rBase.fg(t.muted)), rw, rBase)
  l & m.gutterStyle.render("│") & r

proc uniHalf(m: Model, sign: string, a, b: int, toks: seq[string],
             emph: seq[bool], base, emphS: Style, w: int): string =
  var s: Spans
  s.add(gutter(a, b) & " ", base.fg(m.theme.muted))
  s.add(sign, base)
  for i in 0 ..< toks.len:
    s.add(toks[i], (if i < emph.len and emph[i]: emphS else: base))
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
    for tk in row.lToks: s.add(tk, m.paneStyle)
    @[s.pad(w, m.paneStyle).render()]
  of rkChange:
    @[uniHalf(m, "- ", row.oldNo, 0, row.lToks, row.lEmph,
              m.delStyle, m.delEmphStyle, w),
      uniHalf(m, "+ ", 0, row.newNo, row.rToks, row.rEmph,
              m.addStyle, m.addEmphStyle, w)]
  of rkDel:
    @[uniHalf(m, "- ", row.oldNo, 0, row.lToks, row.lEmph,
              m.delStyle, m.delEmphStyle, w)]
  of rkAdd:
    @[uniHalf(m, "+ ", 0, row.newNo, row.rToks, row.rEmph,
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
  diffCmd(m.root, m.source, m.gen)

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
      return nil
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
  elif k.matches("]"):
    m.list.moveBy(1, m.files.len)
    m.rebuildDiff()
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
    result[0].list.sync d.files.len
    if result[0].list.cursor > max(d.files.high, 0):
      result[0].list.moveTo(max(d.files.high, 0), d.files.len)
    result[0].rebuildDiff()

  elif msg of ErrorMsg:
    result[0].loading = false
    result[1] = result[0].setStatus(
      ErrorMsg(msg).error.msg.splitLines[0], isError = true)

  elif msg of ClearStatusMsg:
    result[0].status = ""
    result[0].statusIsError = false

  elif msg of KeyMsg:
    result[1] = result[0].onKey(KeyMsg(msg))

# --- view --------------------------------------------------------------

proc header(m: Model): string =
  let t = m.theme
  let title = gradientText(" gitdiff", t.ramp, Style().bold())
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
  let legend = t.mutedStyle.render(
    " " & (if m.sideBySide: "side by side" else: "unified") & " · " &
    (if m.wordLevel: "word-diff on" else: "word-diff off") & " · bg " &
    (if m.bg.kind == ckDefault: "unknown"
     elif m.bg.luminance < 0.5: "dark" else: "light"))
  bar & "\n" & statusBar(legend, "", "", m.size.width)

proc footer(m: Model): string =
  let t = m.theme
  if m.status.len > 0:
    return " " & (if m.statusIsError: t.errorStyle.render("✗ " & m.status)
                  else: t.mutedStyle.render(m.status))
  " " & hints({"j/k": "scroll", "tab": "focus", "[/]": "file", "s": "source",
               "b": "layout", "w": "word-diff", "enter": "pager", "q": "quit"})

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
    ("ctrl+d / ctrl+u", "half a page"),
    ("g / G", "top / bottom"),
    ("← →", "scroll a long line sideways (diff, unified only)"),
    ("[ / ]", "previous / next file, without leaving the diff"),
    ("s", "cycle: working tree / staged / since HEAD"),
    ("b", "side by side or unified"),
    ("w", "intra-line (word) highlighting on / off"),
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
                 gen: 1, wordLevel: true, sideBySide: true)
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

  # `enter` hands off to git's pager; under runHeadless no child runs, so `then`
  # is called with an error and the status line says so rather than hanging.
  # `maxTimers = 0`: headless timers fire immediately, so the `ClearStatusMsg`
  # that `setStatus` arms would otherwise wipe what is being asserted.
  var e = fixture()
  let final = newProgram(e, update, view).runHeadless(
    @[Msg(KeyMsg(key: kEnter))], maxTimers = 0)
  doAssert final.statusIsError and final.status.len > 0
  echo "ok — enter hands off to git's pager, and answers under runHeadless"

  echo "all good"

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--selftest":
    selfTest()
    quit(0)

  let path = if paramCount() > 0: paramStr(1).absolutePath else: getCurrentDir()
  var model = Model(theme: DefaultTheme, source: dsWorking, loading: true,
                    gen: 1, wordLevel: true, sideBySide: true)
  model.list = initListView(height = 10, wrapAround = false)
  model.diff = initTextArea(width = 40, height = 10, wrap = false)
  model.applyBackground(Color())        # until the terminal says otherwise

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor, poQueryBackground},
                     initCmd = rootCmd(path)).run()
