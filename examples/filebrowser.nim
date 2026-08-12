## A two-pane file browser.
##
## What this example is really about: doing IO inside commands. Reading a
## directory can fail (permissions, races), and the interesting property is that
## a raising command becomes an `ErrorMsg` instead of unwinding the loop and
## leaving the terminal in raw mode — try navigating into /proc/1 or /root.
##
## Also shows: scrolling viewport with a scrollbar, a split layout that
## reflows on resize, derived state (the preview) refreshed by a command
## whenever the selection moves, and `execCmd` — `e` hands the terminal to
## `$EDITOR` and takes it back when that exits.
##
##   nim c -r --path:src examples/filebrowser.nim

import std/[os, strutils, algorithm, times, math]
import nimtui

const PreviewLines = 200

type
  Entry = object
    name: string
    isDir: bool
    size: int64
    modified: Time

  DirLoadedMsg = ref object of Msg
    path: string
    entries: seq[Entry]

  PreviewLoadedMsg = ref object of Msg
    path: string
    lines: seq[string]

  ClearStatusMsg = ref object of Msg

  EditedMsg = ref object of Msg
    ## `$EDITOR` has exited. Its own message rather than a `Cmd`, because
    ## `execCmd`'s continuation returns a `Msg` — the command that produced it
    ## has already run.

  Model = object
    cwd: string
    entries: seq[Entry]
    cursor: int
    vp: Viewport
    preview: seq[string]
    previewOf: string
    status: string
    statusIsError: bool
    showHidden: bool
    size: TermSize

# --- commands -----------------------------------------------------------------

proc readEntries(path: string, showHidden: bool): seq[Entry] =
  # checkDir defaults to false, which turns an unreadable directory into a
  # silently empty listing. We want the OSError so it reaches the status line.
  for kind, p in walkDir(path, checkDir = true):
    let name = p.extractFilename
    if not showHidden and name.startsWith("."): continue
    var e = Entry(name: name, isDir: kind in {pcDir, pcLinkToDir})
    # A dangling symlink or a file removed mid-scan must not abort the listing.
    try:
      let info = getFileInfo(p, followSymlink = false)
      e.size = info.size
      e.modified = info.lastWriteTime
    except OSError, IOError:
      discard
    result.add e
  result.sort proc (a, b: Entry): int =
    if a.isDir != b.isDir: (if a.isDir: -1 else: 1)
    else: cmpIgnoreCase(a.name, b.name)

proc loadDir(path: string, showHidden: bool): Cmd =
  result = proc (): Msg =
    # Raises on an unreadable directory; the runtime turns that into an ErrorMsg.
    DirLoadedMsg(path: path, entries: readEntries(path, showHidden))

proc isProbablyText(s: string): bool =
  for c in s:
    if c == '\0': return false
  true

proc loadPreview(path: string, isDir: bool): Cmd =
  result = proc (): Msg =
    var lines: seq[string]
    if isDir:
      var dirs, files = 0
      for kind, _ in walkDir(path):
        if kind in {pcDir, pcLinkToDir}: dirs.inc else: files.inc
      lines = @["", "  " & $dirs & " directories", "  " & $files & " files"]
    else:
      var f: File
      if f.open(path, fmRead):
        defer: f.close()
        var line: string
        var n = 0
        while n < PreviewLines and f.readLine(line):
          lines.add(if line.isProbablyText: line
                    else: "· binary file ·")
          if not line.isProbablyText: break
          n.inc
      else:
        lines = @["", "  (cannot read)"]
    PreviewLoadedMsg(path: path, lines: lines)

# --- update -------------------------------------------------------------------

proc listHeight(m: Model): int = max(m.size.height - 6, 1)

proc selected(m: Model): Entry =
  if m.cursor < m.entries.len: m.entries[m.cursor] else: Entry()

proc selectedPath(m: Model): string =
  if m.entries.len == 0: "" else: m.cwd / m.selected.name

proc refreshPreview(m: Model): Cmd =
  if m.entries.len == 0: return nil
  loadPreview(m.selectedPath, m.selected.isDir)

proc move(m: var Model, delta: int): Cmd =
  if m.entries.len == 0: return nil
  m.cursor = clamp(m.cursor + delta, 0, m.entries.high)
  m.vp.ensureVisible(m.cursor, m.entries.len)
  m.refreshPreview()

proc enter(m: var Model): Cmd =
  if m.entries.len == 0 or not m.selected.isDir: return nil
  loadDir(m.selectedPath, m.showHidden)

proc goUp(m: var Model): Cmd =
  let parent = m.cwd.parentDir
  if parent.len == 0 or parent == m.cwd: return nil
  loadDir(parent, m.showHidden)

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if result[0].size.handleResize(msg):
    result[0].vp.height = result[0].listHeight
    result[0].vp.ensureVisible(result[0].cursor, m.entries.len)

  elif msg of DirLoadedMsg:
    let d = DirLoadedMsg(msg)
    result[0].cwd = d.path
    result[0].entries = d.entries
    result[0].cursor = 0
    result[0].vp.top = 0
    result[0].status = $d.entries.len & " items"
    result[0].statusIsError = false
    if d.entries.len == 0:
      # `refreshPreview` has nothing to load here, so no PreviewLoadedMsg is
      # coming to replace what is on screen — clear it, or the previous
      # directory's file stays rendered under this directory's title.
      result[0].preview = @[]
      result[0].previewOf = ""
    result[1] = batch(result[0].refreshPreview(),
                      after(initDuration(seconds = 3), ClearStatusMsg()))

  elif msg of PreviewLoadedMsg:
    let p = PreviewLoadedMsg(msg)
    # Ignore a preview that arrived for a selection we have already left.
    if p.path == m.selectedPath:
      result[0].preview = p.lines
      result[0].previewOf = p.path

  elif msg of ErrorMsg:
    result[0].status = ErrorMsg(msg).error.msg.splitLines[0]
    result[0].statusIsError = true
    result[1] = after(initDuration(seconds = 4), ClearStatusMsg())

  elif msg of EditedMsg:
    # Reload rather than trust: whatever ran may have renamed, deleted or
    # created files, and the preview on screen is of the version from before.
    result[1] = loadDir(m.cwd, m.showHidden)

  elif msg of ClearStatusMsg:
    result[0].status = ""
    result[0].statusIsError = false

  elif msg of MouseMsg:
    let e = MouseMsg(msg)
    case e.button
    of mbWheelUp: result[1] = result[0].move(-3)
    of mbWheelDown: result[1] = result[0].move(3)
    else: discard

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("down", "j"): result[1] = result[0].move(1)
    elif k.matches("up", "k"): result[1] = result[0].move(-1)
    elif k.matches("ctrl+d", "pgdown"): result[1] = result[0].move(m.listHeight div 2)
    elif k.matches("ctrl+u", "pgup"): result[1] = result[0].move(-(m.listHeight div 2))
    elif k.matches("g", "home"): result[1] = result[0].move(-m.entries.len)
    elif k.matches("G", "end"): result[1] = result[0].move(m.entries.len)
    elif k.matches("enter", "l", "right"): result[1] = result[0].enter()
    elif k.matches("backspace", "h", "left"): result[1] = result[0].goUp()
    elif k.matches("r"): result[1] = loadDir(m.cwd, m.showHidden)
    elif k.matches("."):
      result[0].showHidden = not m.showHidden
      result[1] = loadDir(m.cwd, result[0].showHidden)
    elif k.matches("~"): result[1] = loadDir(getHomeDir(), m.showHidden)
    elif k.matches("e"):
      # `execCmd`: the terminal goes back to a cooked state, the editor gets it,
      # and the runtime takes it back and repaints when the editor exits. The
      # loop is single-threaded and commands are already synchronous, so a child
      # process needs no machinery — it is a very long command.
      #
      # The directory is reloaded rather than trusted afterwards, since the file
      # may have been renamed, deleted or created by whatever ran.
      let sel = m.selectedPath
      if sel.len > 0 and not m.selected.isDir:
        result[1] = execCmd(getEnv("EDITOR", "vi"), [sel],
                            proc (r: ExecResult): Msg =
                              if r.error != nil: ErrorMsg(error: r.error)
                              else: EditedMsg())

# --- view ---------------------------------------------------------------------

const
  DirColour = rgb(120, 180, 255)
  Accent = rgb(250, 190, 100)

proc humanSize(n: int64): string =
  if n < 1024: return $n & "B"
  const units = ["K", "M", "G", "T"]
  var v = n.float / 1024.0
  var i = 0
  while v >= 1024.0 and i < units.high:
    v /= 1024.0
    i.inc
  # formatFloat with 0 decimals leaves a trailing point, hence the int path.
  (if v < 10: formatFloat(v, ffDecimal, 1) else: $v.round.int) & units[i]

proc entryLine(m: Model, idx: int, width: int): string =
  let e = m.entries[idx]
  let sel = idx == m.cursor
  let icon = if e.isDir: "▸ " else: "  "
  let meta = (if e.isDir: "" else: humanSize(e.size).align(6)) & " " &
             (if e.modified == Time(): "" else: e.modified.format("yyyy-MM-dd"))
  let room = max(width - displayWidth(meta) - 3, 4)
  let name = elide(e.name, room)
  var line = icon & padVisible(name, room) & " " & meta
  line = padVisible(line, width)
  if sel:
    Style().bg(rgb(60, 70, 90)).fg(rgb(255, 255, 255)).bold().render(line)
  elif e.isDir:
    Style().fg(DirColour).render(line)
  else:
    line

proc listPane(m: Model, width, height: int): string =
  var rows: seq[string]
  let inner = width - 3                     # borders plus scrollbar gutter
  if m.entries.len == 0:
    rows.add Style().faint().render(padVisible("  (empty)", inner))
  for idx in m.vp.top ..< min(m.vp.top + height - 2, m.entries.len):
    rows.add m.entryLine(idx, inner)
  while rows.len < height - 2: rows.add ' '.repeat(inner)
  let withBar = m.vp.withScrollbar(rows, m.entries.len)
  renderBox(withBar.join("\n"), width, height,
            title = $(m.cursor + 1) & "/" & $m.entries.len,
            borderStyle = Style().faint())

proc previewPane(m: Model, width, height: int): string =
  let inner = width - 2
  var rows: seq[string]
  for line in m.preview:
    if rows.len >= height - 2: break
    rows.add truncateVisible(line.replace("\t", "    "), inner)
  let title = if m.entries.len == 0: "preview" else: m.selected.name
  renderBox(rows.join("\n"), width, height, title = title,
            borderStyle = Style().faint(),
            titleStyle = Style().fg(Accent))

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let bodyHeight = max(m.size.height - 3, 3)
  let header = Style().bold().fg(Accent).render(" " & m.cwd) &
    (if m.showHidden: Style().faint().render("  (showing hidden)") else: "")

  # Below 80 columns the preview is dropped rather than squeezed to nothing.
  let body =
    if m.size.width < 80:
      m.listPane(m.size.width, bodyHeight)
    else:
      let listWidth = max(m.size.width * 2 div 5, 34)
      joinHorizontal([m.listPane(listWidth, bodyHeight),
                      m.previewPane(m.size.width - listWidth, bodyHeight)])

  let status =
    if m.status.len == 0: hints({"j/k": "move", "enter": "open", "e": "edit",
                                 "h": "up", ".": "hidden", "q": "quit"})
    elif m.statusIsError: Style().fg(rgb(255, 110, 110)).bold().render("✗ " & m.status)
    else: Style().faint().render(m.status)

  joinVertical(header, body, " " & status)

when isMainModule:
  let start = if paramCount() > 0: paramStr(1).absolutePath else: getCurrentDir()
  var model = Model(cwd: start, vp: Viewport(height: 10))
  discard newProgram(model, update, view,
                     # `poMouseClicks`, not a motion level: the only mouse events
                     # this acts on are the wheel, which is reported at every
                     # level, so asking for motion would be asking the terminal
                     # to send a report per cell for the `else: discard` above.
                     options = {poAltScreen, poHideCursor, poMouseClicks},
                     initCmd = loadDir(start, false)).run()
