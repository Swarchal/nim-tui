## The smallest useful program: model, update, view.
##
##   nim c -r --path:src examples/counter.nim

import nimtui

type Model = object
  count: int

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of KeyMsg:
    case $KeyMsg(msg)
    of "q", "ctrl+c", "esc": result[1] = quitCmd()
    of "up", "k", "+": result[0].count.inc
    of "down", "j", "-": result[0].count.dec
    of "r": result[0].count = 0
    else: discard

proc view(m: Model): string =
  let big = Style().bold().fg(rgb(120, 200, 255))
  let dim = Style().faint()
  "\n  " & big.render($m.count) & "\n\n" &
    dim.render("  up/down to change · r to reset · q to quit") & "\n"

when isMainModule:
  let final = newProgram(Model(), update, view).run()
  echo "final count: ", final.count
