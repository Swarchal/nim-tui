## A program that does nothing but hold the terminal, for `signals.py` to kill.
##
##     nim c --path:src tests/manual/signalled.nim
##
## Takes the modes to turn on as arguments — `alt`, `cursor`, `mouse`, `paste`,
## `focus` — so one binary covers every combination of what teardown has to undo.
##
## It renders a line and then waits. That matters for the assertion about the
## trailing newline: the scrollback path emits one only when a block is on
## screen, and a program killed before its first frame is the case the emergency
## restore deliberately gets slightly wrong in the harmless direction.
##
## Deliberately not named `t*`, so `nimble test` does not compile it — it is a
## fixture, and the assertions are in the driver.

import std/os
import nimtui

type Model = object
  ticks: int

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of TickMsg:
    result[0].ticks.inc
    result[1] = tick(initDuration(milliseconds = 50))

proc view(m: Model): string =
  "holding the terminal, tick " & $m.ticks

var options: set[ProgramOption]
for i in 1 .. paramCount():
  case paramStr(i)
  of "alt": options.incl poAltScreen
  of "cursor": options.incl poHideCursor
  of "mouse": options.incl poMouseCellMotion
  of "paste": options.incl poBracketedPaste
  of "focus": options.incl poFocusReporting
  else: quit("unknown mode: " & paramStr(i))

discard newProgram(Model(), update, view, options = options,
                   initCmd = tick(initDuration(milliseconds = 50))).run()
