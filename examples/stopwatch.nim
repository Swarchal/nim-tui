## Timers via `tick`: the update proc re-issues the command each time it fires,
## which is how repeating work is expressed without threads or sleeping.
##
##   nim c -r --path:src examples/stopwatch.nim

import std/[times, strutils]
import nimtui

const Interval = initDuration(milliseconds = 100)

type Model = object
  elapsed: Duration
  running: bool
  lastTick: MonoTime

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of TickMsg:
    if m.running:
      let now = TickMsg(msg).at
      result[0].elapsed += now - m.lastTick
      result[0].lastTick = now
      result[1] = tick(Interval)
  elif msg of KeyMsg:
    case $KeyMsg(msg)
    of "q", "ctrl+c": result[1] = quitCmd()
    of "space":
      result[0].running = not m.running
      if result[0].running:
        result[0].lastTick = getMonoTime()
        result[1] = tick(Interval)
    of "r":
      result[0].elapsed = DurationZero
      result[0].lastTick = getMonoTime()
    else: discard

proc view(m: Model): string =
  let total = m.elapsed.inMilliseconds
  let text = align($(total div 1000), 2, '0') & "." &
             align($((total mod 1000) div 100), 1)
  let face = Style().bold().fg(if m.running: rgb(120, 230, 140)
                               else: rgb(200, 200, 200))
  "\n  " & face.render(text & "s") & "\n\n" &
    Style().faint().render("  space to " &
      (if m.running: "pause" else: "start") & " · r to reset · q to quit") & "\n"

when isMainModule:
  discard newProgram(Model(lastTick: getMonoTime()), update, view).run()
