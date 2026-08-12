## The smallest useful program: model, update, view.
##
##   nim c -r --path:src examples/counter.nim

import nimtui

type Model = object
  count: int

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c", "esc"): result[1] = quitCmd()
    elif k.matches("up", "k", "+"): result[0].count.inc
    elif k.matches("down", "j", "-"): result[0].count.dec
    elif k.matches("r"): result[0].count = 0

proc view(m: Model): string =
  let big = Style().bold().fg(rgb(120, 200, 255))
  let dim = Style().faint()
  "\n  " & big.render($m.count) & "\n\n" &
    dim.render("  up/down to change · r to reset · q to quit") & "\n"

when isMainModule:
  let final = newProgram(Model(), update, view).run()
  echo "final count: ", final.count
