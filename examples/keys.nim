## Input debugger: shows how every keystroke, mouse event, paste and focus change
## decodes. Useful when adding sequences to `nimtui/input`.
##
## Every input option is on here, which is what makes it the place to see what
## each one actually produces — including the pixel size a terminal may or may
## not report.
##
##   nim c -r --path:src examples/keys.nim

import std/strutils
import nimtui

const History = 12

type Model = object
  events: seq[string]
  size: tuple[w, h: int]
  pixels: tuple[w, h: int]
  focused: bool

proc push(m: var Model, s: string) =
  m.events.add s
  if m.events.len > History:
    m.events.delete 0

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of KeyMsg:
    let k = KeyMsg(msg)
    result[0].push "key   " & $k & "  (key=" & $k.key & " mods=" & $k.mods & ")"
    if $k in ["q", "ctrl+c"]:
      result[1] = quitCmd()
  elif msg of MouseMsg:
    let e = MouseMsg(msg)
    result[0].push "mouse " & $e.action & " " & $e.button &
                   " at " & $e.x & "," & $e.y
  elif msg of WindowSizeMsg:
    let w = WindowSizeMsg(msg)
    result[0].size = (w.width, w.height)
    result[0].pixels = (w.pixelWidth, w.pixelHeight)
    result[0].push "resize " & $w.width & "x" & $w.height &
                   (if w.pixelWidth > 0: "  " & $w.pixelWidth & "x" &
                                         $w.pixelHeight & "px"
                    else: "  (no pixel size)")
  elif msg of FocusMsg:
    result[0].focused = FocusMsg(msg).focused
    result[0].push "focus " & (if FocusMsg(msg).focused: "in" else: "out")
  elif msg of PasteMsg:
    let t = PasteMsg(msg).text
    result[0].push "paste " & $t.len & " bytes: " & oneLine(t).elide(40)

proc view(m: Model): string =
  var dims = "  " & $m.size.w & "x" & $m.size.h
  if m.pixels.w > 0:
    # Cell size in pixels — the number an image protocol needs, and the only one
    # here that cannot be worked out from anything else.
    dims.add "  cell " & $(m.pixels.w div max(m.size.w, 1)) & "x" &
             $(m.pixels.h div max(m.size.h, 1)) & "px"
  let head = Style().bold().render("input events") &
             Style().faint().render(dims) &
             (if m.focused: "" else: Style().faint().render("  · unfocused"))
  var lines = @["", "  " & head, ""]
  for i in 0 ..< History:
    let idx = m.events.len - History + i
    lines.add "  " & (if idx >= 0: m.events[idx] else: "")
  lines.add ""
  lines.add Style().faint().render(
    "  press keys, paste, click, switch window · q to quit")
  lines.join("\n")

when isMainModule:
  discard newProgram(Model(), update, view,
                     options = {poAltScreen, poHideCursor, poMouseCellMotion,
                                poBracketedPaste, poFocusReporting}).run()
