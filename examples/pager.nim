## A file pager with incremental search: `less`, in about two hundred lines.
##
## What this example is really about: `TextArea` as it is actually used, which
## means confronting the one awkward thing about wrapped text. Scroll positions
## are indices into the *wrapped* lines, not the source lines, and once a line
## can become three there is no longer a correspondence between the two. So a
## search cannot find a hit in `lines` and scroll to it — it has to find it in
## `wrappedLines`, which is why that accessor exists.
##
## Also shows the other half of a two-mode UI: `/` hands the keyboard to a
## `TextInput`, and everything else goes to the pager. The rule that keeps that
## honest is that each component's `handleKey` returns whether it wanted the
## key, so the dispatch is a fall-through rather than a growing `if` over modes.
##
##   nim c -r --path:src examples/pager.nim [file]

import std/[os, math, strutils, strformat]
import nimtui

type
  Mode = enum
    mNormal, mSearching

  Model = object
    path: string
    lines: seq[string]         ## the source, unhighlighted
    ta: TextArea
    query: TextInput
    committed: string          ## the query the highlights were built from
    matches: seq[int]          ## indices into `ta.wrappedLines`
    matchIdx: int
    mode: Mode
    size: TermSize
    theme: Theme
    status: string

const SampleText = """
nimtui pager

No file was given and this program's own source could not be found, so here is
some filler to page through instead. Press / to search it, n and N to walk the
hits, w to toggle wrapping, and q to quit.

The point of the example is the relationship between source lines and wrapped
lines. Turn wrapping off with w and this paragraph becomes one very long line
that scrolls sideways with the arrow keys; turn it back on and it becomes
several, and every scroll position changes meaning.
"""

# --- searching ----------------------------------------------------------------

proc highlight(line, query: string, style: Style): string =
  ## `line` with every occurrence of `query` styled. Case-insensitive.
  ##
  ## Built as `Spans` rather than by splicing escape sequences into the string:
  ## the runs carry their styling separately until `render`, so nothing here has
  ## to reason about where a previous escape ended.
  if query.len == 0: return line
  let
    hay = line.toLowerAscii          # ASCII-lowering preserves byte length, so
    needle = query.toLowerAscii      # offsets into it are offsets into `line`
  var
    painted = Spans()
    i = 0
  while i <= line.len:
    let j = hay.find(needle, i)
    if j < 0:
      painted.add line[i .. ^1]
      break
    painted.add line[i ..< j]
    painted.add(line[j ..< j + query.len], style)
    i = j + query.len
  painted.render()

proc applyQuery(m: var Model) =
  ## Rebuild the pane's content with the current query highlighted, then find
  ## the hits in the wrapped form.
  ##
  ## Rebuilding the whole buffer on every keystroke is fine at this scale and
  ## wrong at a much larger one; a pager over a 200MB log would highlight only
  ## the visible window. Doing it wholesale keeps the wrap cache and the
  ## highlights in step, which is the part that is easy to get wrong.
  let q = m.query.text
  if q.len == 0:
    m.ta.setLines m.lines
  else:
    var painted = newSeqOfCap[string](m.lines.len)
    for line in m.lines:
      painted.add highlight(line, q, m.theme.selectionStyle)
    m.ta.setLines painted
  m.committed = q

  m.matches.setLen 0
  if q.len > 0:
    let needle = q.toLowerAscii
    for i, line in m.ta.wrappedLines:
      # The wrapped line carries escapes now, so match against the visible text.
      # A hit split across a wrap boundary is missed; `less` has the same
      # limitation, and fixing it means searching before wrapping and mapping
      # the offset forward.
      if line.stripAnsi.toLowerAscii.contains(needle): m.matches.add i
  m.matchIdx = 0

proc jumpTo(m: var Model, idx: int) =
  if m.matches.len == 0: return
  m.matchIdx = floorMod(idx, m.matches.len)
  m.ta.centerOn m.matches[m.matchIdx]

proc nextMatch(m: var Model, delta: int) =
  if m.matches.len == 0:
    m.status = "no matches"
    return
  m.jumpTo m.matchIdx + delta
  m.status = ""

# --- geometry -----------------------------------------------------------------

proc paneHeight(m: Model): int = max(m.size.height - 2, 3)

proc relayout(m: var Model) =
  m.ta.resize(max(m.size.width - 4, 4), max(m.paneHeight - 4, 1))

# --- update -------------------------------------------------------------------

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if result[0].size.handleResize(msg):
    result[0].relayout()
    # The wrap width changed, so every recorded match index is now stale.
    if result[0].committed.len > 0: result[0].applyQuery()

  elif msg of ErrorMsg:
    result[0].status = ErrorMsg(msg).error.msg.splitLines[0]

  elif msg of KeyMsg:
    let k = KeyMsg(msg)

    if m.mode == mSearching:
      case $k
      of "enter":
        result[0].mode = mNormal
        result[0].applyQuery()
        if result[0].matches.len == 0:
          result[0].status = &"not found: {result[0].query.text}"
        else:
          result[0].jumpTo 0
          result[0].status = ""
      of "esc":
        result[0].mode = mNormal
        result[0].query.clear()
        result[0].applyQuery()
        result[0].status = ""
      else:
        # Anything the field wants is text; anything it does not is ignored
        # rather than falling through, so a stray ctrl+key cannot scroll the
        # pane out from under a half-typed query.
        if result[0].query.handleKey(k):
          result[0].applyQuery()      # live highlighting as you type
      return

    # Normal mode: the pane gets first refusal on every key.
    if result[0].ta.handleKey(k): return

    case $k
    of "q", "ctrl+c": result[1] = quitCmd()
    of "/":
      result[0].mode = mSearching
      result[0].query.clear()
      result[0].status = ""
    of "n": result[0].nextMatch 1
    of "N": result[0].nextMatch(-1)
    of "w":
      result[0].ta.wrap = not m.ta.wrap
      result[0].ta.xOffset = 0
      result[0].ta.reflow()
      if result[0].committed.len > 0: result[0].applyQuery()
      result[0].status = if result[0].ta.wrap: "wrap on" else: "wrap off"
    else: discard

# --- view ---------------------------------------------------------------------

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let
    t = m.theme
    w = m.size.width

  let header = statusBar(
    " " & gradientText(m.path.lastPathPart, t.ramp, Style().bold()),
    "",
    t.mutedStyle.render(&"{m.lines.len} lines · {m.ta.lineCount} wrapped "), w)

  let counter =
    if m.committed.len == 0: ""
    elif m.matches.len == 0: t.warnStyle.render(" no match ")
    else: t.accentStyle.render(&" {m.matchIdx + 1}/{m.matches.len} ")

  let pane = panel(RoundedBorder)
    .title(" " & m.path.lastPathPart & " ")
    .footer(counter & t.mutedStyle.render(&" {m.ta.positionLabel} "))
    .pad(1)
    .styled(border = t.borderStyle, title = t.titleStyle)
    .render(m.ta.render(), w, m.paneHeight)

  let bottom =
    if m.mode == mSearching:
      t.accentStyle.render(" /") & m.query.render(max(w - 2, 1))
    elif m.status.len > 0:
      statusBar(" " & t.warnStyle.render(m.status), "", "", w)
    else:
      statusBar(" " & hints({"/": "search", "n": "next", "w": "wrap",
                             "j/k": "scroll", "q": "quit"}), "", "", w)

  joinVertical(header, pane, bottom)

when isMainModule:
  var model = Model(theme: DefaultTheme, query: initTextInput("search"))
  model.ta = initTextArea()
  model.ta.lineStyle = Style()

  # `currentSourcePath` is baked in at compile time, so the default works
  # wherever the binary ends up — `nimble examples` puts it in bin/.
  model.path = if paramCount() > 0: paramStr(1) else: currentSourcePath()
  if fileExists(model.path):
    model.lines = readFile(model.path).splitLines
  else:
    model.path = "(sample)"
    model.lines = SampleText.splitLines
  model.ta.setLines model.lines

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor}).run()
