## A program that does nothing but hold the terminal, for `signals.py` to kill.
##
##     nim c --path:src tests/manual/signalled.nim
##
## Takes the modes to turn on as arguments — `alt`, `cursor`, `clicks`, `mouse`,
## `allmotion`, `paste`, `focus` — so one binary covers every combination of what
## teardown has to undo. The three mouse levels are separate arguments because
## they are separate options that all map to `tmMouse`: the interesting case is
## that the *same* teardown undoes each of them.
##
## `out:<path>` draws to that tty instead of to stdout, which is how the driver
## gets input and output onto two different devices. `run` takes them as two
## parameters, so they need not be the same one — and the armed restore has to
## write its escapes to the one being *drawn* to while putting the `Termios` back
## on the one raw mode was set on. Under `pty.fork` alone those are the same fd
## and a handler that confuses them looks perfect.
##
## Typing `z` at it returns `suspendCmd()`, which is the explicit half of the
## suspend work; an externally delivered SIGTSTP is the other half and needs
## nothing here.
##
## It renders a line and then waits. That matters for the assertion about the
## trailing newline: the scrollback path emits one only when a block is on
## screen, and a program killed before its first frame is the case the emergency
## restore deliberately gets slightly wrong in the harmless direction.
##
## Deliberately not named `t*`, so `nimble test` does not compile it — it is a
## fixture, and the assertions are in the driver.

import std/[os, strutils]
import nimtui

type Model = object
  ticks: int

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of TickMsg:
    result[0].ticks.inc
    result[1] = tick(initDuration(milliseconds = 50))
  # `z` rather than ctrl+z, and that is the point rather than a shortcut: with
  # ISIG cleared, ctrl+z is an ordinary key and binding it is the application's
  # decision, so what the driver has to exercise is a program *choosing* to
  # suspend. The route from here is identical either way.
  elif msg of KeyMsg and $KeyMsg(msg) == "z":
    result[1] = suspendCmd()

proc view(m: Model): string =
  "holding the terminal, tick " & $m.ticks

var
  options: set[ProgramOption]
  outPath = ""
for i in 1 .. paramCount():
  let arg = paramStr(i)
  case arg
  of "alt": options.incl poAltScreen
  of "cursor": options.incl poHideCursor
  of "clicks": options.incl poMouseClicks
  of "mouse": options.incl poMouseCellMotion
  of "allmotion": options.incl poMouseAllMotion
  of "paste": options.incl poBracketedPaste
  of "focus": options.incl poFocusReporting
  else:
    if arg.startsWith("out:"): outPath = arg[4 .. ^1]
    else: quit("unknown mode: " & arg)

let program = newProgram(Model(), update, view, options = options,
                         initCmd = tick(initDuration(milliseconds = 50)))
if outPath.len > 0:
  discard program.run(input = stdin, output = open(outPath, fmWrite))
else:
  discard program.run()
