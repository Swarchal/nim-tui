## A task list with modal editing and live filtering.
##
## What this example is really about: a model with modes. `update` dispatches on
## `m.mode` *before* the key, which is what keeps a text field from swallowing
## `q` and what keeps `j`/`k` from being typed into a task title. The text input
## reports whether it consumed a key, so `enter` and `esc` stay with the caller.
##
## Also shows: transient status messages that expire via `after`, and a filtered
## view where the cursor tracks the *filtered* list rather than the underlying one.
##
##   nim c -r --path:src examples/todo.nim

import std/[strutils, sequtils, unicode]
import nimtui
import lib/[textinput, viewport]

type
  Mode = enum
    mNormal, mAdding, mEditing, mFiltering

  Task = object
    title: string
    done: bool

  ClearFlashMsg = ref object of Msg

  Model = object
    tasks: seq[Task]
    cursor: int             ## index into the *filtered* list
    mode: Mode
    input: TextInput
    filter: TextInput
    vp: Viewport
    flash: string
    width, height: int

const Seed = [
  ("write the input decoder", true),
  ("make the renderer skip unchanged frames", true),
  ("handle SIGWINCH", true),
  ("decide whether commands should be async", false),
  ("add a viewport widget", false),
  ("double-width character support in displayWidth", false),
  ("bracketed paste", false),
  ("windows support", false),
]

# --- filtering ----------------------------------------------------------------

proc matches(t: Task, needle: string): bool =
  needle.len == 0 or needle.toLower in t.title.toLower

proc visibleIndices(m: Model): seq[int] =
  let needle = m.filter.text
  for i, t in m.tasks:
    if t.matches(needle): result.add i

proc realIndex(m: Model): int =
  ## Map the cursor onto the underlying task list, or -1 when nothing matches.
  let vis = m.visibleIndices
  if m.cursor < vis.len: vis[m.cursor] else: -1

proc flash(m: var Model, s: string): Cmd =
  m.flash = s
  after(initDuration(milliseconds = 2500), ClearFlashMsg())

# --- update -------------------------------------------------------------------

proc listHeight(m: Model): int = max(m.height - 9, 1)

proc clampCursor(m: var Model) =
  let total = m.visibleIndices.len
  m.cursor = clamp(m.cursor, 0, max(total - 1, 0))
  m.vp.height = m.listHeight
  m.vp.ensureVisible(m.cursor, total)

proc commitInput(m: var Model): Cmd =
  let text = m.input.text.strip
  case m.mode
  of mAdding:
    if text.len > 0:
      m.tasks.add Task(title: text)
      m.cursor = m.visibleIndices.high
      result = m.flash("added")
    else:
      result = m.flash("nothing to add")
  of mEditing:
    let idx = m.realIndex
    if idx >= 0 and text.len > 0:
      m.tasks[idx].title = text
      result = m.flash("updated")
  else: discard
  m.input.clear()
  m.mode = mNormal
  m.clampCursor()

proc handleNormalKey(m: var Model, k: KeyMsg): Cmd =
  let idx = m.realIndex
  case $k
  of "q", "ctrl+c": return quitCmd()
  of "down", "j":
    m.cursor.inc
    m.clampCursor()
  of "up", "k":
    m.cursor = max(m.cursor - 1, 0)
    m.clampCursor()
  of "g": m.cursor = 0; m.clampCursor()
  of "G": m.cursor = m.visibleIndices.len; m.clampCursor()
  of "space", "enter", "x":
    if idx >= 0:
      m.tasks[idx].done = not m.tasks[idx].done
  of "a", "n":
    m.mode = mAdding
    m.input = initTextInput("what needs doing?")
  of "e":
    if idx >= 0:
      m.mode = mEditing
      m.input = initTextInput()
      m.input.text = m.tasks[idx].title
  of "d":
    if idx >= 0:
      let title = m.tasks[idx].title
      m.tasks.delete idx
      m.clampCursor()
      return m.flash("deleted " & title.elide(24))
  of "J":                                   # reorder down
    if idx >= 0 and idx < m.tasks.high:
      swap m.tasks[idx], m.tasks[idx + 1]
      m.cursor.inc
      m.clampCursor()
  of "K":                                   # reorder up
    if idx > 0:
      swap m.tasks[idx], m.tasks[idx - 1]
      m.cursor = max(m.cursor - 1, 0)
      m.clampCursor()
  of "c":
    let before = m.tasks.len
    m.tasks.keepItIf(not it.done)
    m.clampCursor()
    return m.flash($(before - m.tasks.len) & " completed cleared")
  of "/":
    m.mode = mFiltering
  of "esc":
    if not m.filter.isEmpty:
      m.filter.clear()
      m.clampCursor()
      return m.flash("filter cleared")
  else: discard

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of WindowSizeMsg:
    let w = WindowSizeMsg(msg)
    result[0].width = w.width
    result[0].height = w.height
    result[0].clampCursor()

  elif msg of ClearFlashMsg:
    result[0].flash = ""

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    case m.mode
    of mNormal:
      result[1] = result[0].handleNormalKey(k)
    of mAdding, mEditing:
      case $k
      of "enter": result[1] = result[0].commitInput()
      of "esc":
        result[0].input.clear()
        result[0].mode = mNormal
      of "ctrl+c": result[1] = quitCmd()
      else:
        discard result[0].input.handleKey(k)
    of mFiltering:
      case $k
      of "enter", "esc":
        result[0].mode = mNormal
        result[0].clampCursor()
      of "ctrl+c": result[1] = quitCmd()
      else:
        if result[0].filter.handleKey(k):
          result[0].cursor = 0
          result[0].clampCursor()

# --- view ---------------------------------------------------------------------

const
  Accent = rgb(180, 150, 255)
  DoneColour = rgb(120, 200, 140)

proc findFold(title, needle: string): (int, int) =
  ## Byte offset and byte length, *in `title`*, of the first case-insensitive
  ## match of `needle`, or `(-1, 0)` for no match.
  ##
  ## Not `title.toLower.find(needle.toLower)`: that yields an offset into the
  ## lowercased string, and `toLower` can change a rune's byte length — `İ` is two
  ## bytes and lowercases to one — so reusing the offset against the original
  ## slices it mid-rune. The result is invalid UTF-8, which `displayWidth` then
  ## measures as stray columns and the line comes out the wrong width.
  let n = needle.toLower
  if n.len == 0: return (0, 0)
  var i = 0
  while i < title.len:
    var ti = i
    var ni = 0
    var matched = true
    while ni < n.len:
      if ti >= title.len:
        matched = false
        break
      var tr, nr: Rune
      fastRuneAt(title, ti, tr, true)
      fastRuneAt(n, ni, nr, true)
      if tr.toLower != nr:
        matched = false
        break
    if matched: return (i, ti - i)
    var skip: Rune
    fastRuneAt(title, i, skip, true)      # advance one whole rune
  (-1, 0)

proc highlight(title, needle: string, base: Style): string =
  ## Underline the matched span so it is visible even without colour.
  if needle.len == 0: return base.render(title)
  let (at, span) = findFold(title, needle)
  if at < 0: return base.render(title)
  base.render(title[0 ..< at]) &
    base.underline().bold().render(title[at ..< at + span]) &
    base.render(title[at + span .. ^1])

proc taskLine(m: Model, row: int, taskIdx: int, width: int): string =
  let t = m.tasks[taskIdx]
  let sel = row == m.cursor
  let mark = if t.done: "✔ " else: "○ "
  var base = Style()
  if t.done: base = base.faint()
  if sel: base = base.bold()
  let room = max(width - 4, 4)
  let title = highlight(elide(t.title, room), m.filter.text, base)
  let markStyle = if t.done: Style().fg(DoneColour) else: Style().faint()
  let line = padVisible("  " & markStyle.render(mark) & title, width)
  if sel: Style().bg(rgb(55, 45, 80)).render(line) else: line

proc listPane(m: Model, width, height: int): string =
  let vis = m.visibleIndices
  let inner = width - 3
  var rows: seq[string]
  if vis.len == 0:
    rows.add Style().faint().render(padVisible(
      if m.tasks.len == 0: "  nothing to do" else: "  no matches", inner))
  for row in m.vp.top ..< min(m.vp.top + height - 2, vis.len):
    rows.add m.taskLine(row, vis[row], inner)
  while rows.len < height - 2: rows.add ' '.repeat(inner)
  let title = if m.filter.isEmpty: "tasks"
              else: "tasks matching “" & m.filter.text & "”"
  renderBox(m.vp.withScrollbar(rows, vis.len).join("\n"), width, height,
            title = title, borderStyle = Style().faint(),
            titleStyle = Style().fg(Accent))

proc progressPane(m: Model, width: int): string =
  let done = m.tasks.countIt(it.done)
  let frac = if m.tasks.len == 0: 0.0 else: done / m.tasks.len
  let label = $done & "/" & $m.tasks.len & "  " & $int(frac * 100) & "%"
  let barWidth = max(width - displayWidth(label) - 6, 4)
  let bar = Style().fg(DoneColour).render(gauge(frac, barWidth))
  renderBox("  " & bar & "  " & Style().bold().render(label), width, 3,
            borderStyle = Style().faint())

proc inputPane(m: Model, width: int): string =
  let prompt = case m.mode
               of mAdding: "new: "
               of mEditing: "edit: "
               of mFiltering: "filter: "
               of mNormal: ""
  if m.mode == mNormal: return ""
  let field = if m.mode == mFiltering: m.filter else: m.input
  let inner = width - 2 - displayWidth(prompt) - 2
  renderBox("  " & Style().fg(Accent).bold().render(prompt) &
            field.render(inner), width, 3,
            borderStyle = Style().fg(Accent))

proc view(m: Model): string =
  if m.width == 0: return "loading…"
  let width = min(m.width, 96)
  let inputHeight = if m.mode == mNormal: 0 else: 3
  let listHeight = max(m.height - 5 - inputHeight, 3)

  let header = Style().bold().fg(Accent).render("  things to do") &
    (if m.flash.len > 0: Style().faint().render("   " & m.flash) else: "")

  let footer = " " & (case m.mode
    of mNormal: hints({"a": "add", "e": "edit", "d": "delete", "space": "toggle",
                       "J/K": "move", "/": "filter", "c": "clear done", "q": "quit"})
    of mAdding, mEditing: hints({"enter": "save", "esc": "cancel",
                                 "ctrl+w": "delete word", "ctrl+u": "clear"})
    of mFiltering: hints({"enter": "apply", "esc": "done", "ctrl+u": "clear"}))

  var parts = @[header, m.listPane(width, listHeight),
                m.progressPane(width)]
  if inputHeight > 0: parts.add m.inputPane(width)
  parts.add footer
  parts.join("\n")

when isMainModule:
  var model = Model(input: initTextInput(), filter: initTextInput("substring"),
                    vp: Viewport(height: 10))
  for (title, done) in Seed:
    model.tasks.add Task(title: title, done: done)
  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor}).run()
