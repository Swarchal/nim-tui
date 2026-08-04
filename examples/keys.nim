## Input debugger: shows how every keystroke and mouse event decodes. Useful
## when adding sequences to `nimtui/input`.
##
##   nim c -r --path:src examples/keys.nim

import std/strutils
import nimtui

const History = 12

type Model = object
  events: seq[string]
  size: tuple[w, h: int]

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
    result[0].push "resize " & $w.width & "x" & $w.height

proc view(m: Model): string =
  let head = Style().bold().render("input events") &
             Style().faint().render("  " & $m.size.w & "x" & $m.size.h)
  var lines = @["", "  " & head, ""]
  for i in 0 ..< History:
    let idx = m.events.len - History + i
    lines.add "  " & (if idx >= 0: m.events[idx] else: "")
  lines.add ""
  lines.add Style().faint().render("  press keys · q to quit")
  lines.join("\n")

when isMainModule:
  discard newProgram(Model(), update, view,
                     options = {poAltScreen, poHideCursor, poMouseCellMotion}).run()
