## Timers via `tick`: the update proc re-issues the command each time it fires,
## which is how repeating work is expressed without threads or sleeping.
##
## The face is `bigDigits`, since a clock is what three rows of numerals are for.
## It also carries the one thing about the two weights that has to be true and is
## easy to break: they are the *same size*, so the display does not jump when the
## watch stops and the face drops from bold to thin.
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
  let
    total = m.elapsed.inMilliseconds
    text = align($(total div 60_000), 2, '0') & ":" &
           align($((total mod 60_000) div 1000), 2, '0') & "." &
           $((total mod 1000) div 100)
    face = Style().fg(if m.running: rgb(120, 230, 140)
                      else: rgb(200, 200, 200))
  # Styled a line at a time rather than as one block: the renderer erases to the
  # end of every line it rewrites, so a style left open across a newline is
  # smeared to the right-hand edge of the screen.
  var rows: seq[string]
  for line in bigDigits(text, bold = m.running).split('\n'):
    rows.add "  " & face.render(line)
  "\n" & rows.join("\n") & "\n\n" &
    Style().faint().render("  space to " &
      (if m.running: "pause" else: "start") & " · r to reset · q to quit") & "\n"

when isMainModule:
  discard newProgram(Model(lastTick: getMonoTime()), update, view).run()
