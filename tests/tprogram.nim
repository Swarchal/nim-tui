import std/[unittest, times, unicode, options, strutils]
import nimtui

## `runHeadless` drives the same update/command machinery as `run` without a
## terminal, which is how applications should test their own update procs.

type
  Model = object
    count: int
    log: seq[string]
    ticks: int

  AddMsg = ref object of Msg
    delta: int

  PingMsg = ref object of Msg

proc key(s: string): KeyMsg =
  KeyMsg(key: kRune, rune: s.runeAt(0))

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of AddMsg:
    result[0].count += AddMsg(msg).delta
  elif msg of PingMsg:
    result[0].log.add "ping"
  elif msg of TickMsg:
    result[0].ticks.inc
  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    result[0].log.add $k
    case $k
    of "q": result[1] = quitCmd()
    of "a": result[1] = msgCmd(AddMsg(delta: 1))
    of "b": result[1] = batch(msgCmd(AddMsg(delta: 2)), msgCmd(PingMsg()))
    of "t": result[1] = tick(initDuration(milliseconds = 5))
    of "z": result[1] = suspendCmd()
    else: discard
  elif msg of ErrorMsg:
    result[0].log.add "error: " & ErrorMsg(msg).error.msg
  elif msg of WindowSizeMsg:
    result[0].log.add "size " & $WindowSizeMsg(msg).width
  elif msg of PasteMsg:
    result[0].log.add "paste " & PasteMsg(msg).text

proc view(m: Model): string = "count=" & $m.count

proc prog(initCmd: Cmd = nil): Program[Model] =
  newProgram(Model(), update, view, initCmd = initCmd)

type
  Repeat = object          ## re-arms its timer, so it is never out of timers
    ticks: int
  Chain = object           ## queues the next slice, then stops
    steps: int

proc repeatUpdate(m: Repeat, msg: Msg): (Repeat, Cmd) =
  result = (m, nil)
  if msg of TickMsg:
    result[0].ticks.inc
    result[1] = tick(initDuration(milliseconds = 1))

proc chainUpdate(m: Chain, msg: Msg): (Chain, Cmd) =
  result = (m, nil)
  if msg of TickMsg:
    result[0].steps.inc
    if result[0].steps < 4:
      result[1] = after(DurationZero, TickMsg())

proc repeatProg(): Program[Repeat] =
  newProgram(Repeat(), repeatUpdate, proc (m: Repeat): string = $m.ticks,
             initCmd = tick(initDuration(milliseconds = 1)))

proc chainProg(): Program[Chain] =
  newProgram(Chain(), chainUpdate, proc (m: Chain): string = $m.steps,
             initCmd = after(DurationZero, TickMsg()))

suite "message dispatch":
  test "messages reach update in order":
    let m = prog().runHeadless(@[Msg(key("x")), Msg(key("y"))])
    check m.log == @["x", "y"]

  test "the model threads through updates":
    let m = prog().runHeadless(@[Msg(AddMsg(delta: 3)), Msg(AddMsg(delta: 4))])
    check m.count == 7

  test "view renders the current model":
    let p = prog()
    discard p.runHeadless(@[Msg(AddMsg(delta: 2))])
    check p.view(p.model) == "count=2"

suite "commands":
  test "a returned command's message is fed back in":
    let m = prog().runHeadless(@[Msg(key("a"))])
    check m.count == 1

  test "batch runs every command":
    let m = prog().runHeadless(@[Msg(key("b"))])
    check m.count == 2
    check m.log == @["b", "ping"]

  test "batch drops nil commands and collapses single entries":
    check batch(nil, nil) == nil
    check batch(nil) == nil
    let single = quitCmd()
    check batch(nil, single) == single

  test "the init command runs before any message":
    let m = prog(msgCmd(AddMsg(delta: 5))).runHeadless(@[Msg(key("a"))])
    check m.count == 6

  test "a command raising becomes an ErrorMsg rather than unwinding":
    let boom: Cmd = proc (): Msg =
      raise newException(ValueError, "boom")
    let m = prog(boom).runHeadless(@[])
    check m.log == @["error: boom"]

suite "quitting":
  test "quitCmd stops the loop":
    let m = prog().runHeadless(@[Msg(key("x")), Msg(key("q")), Msg(key("z"))])
    check m.log == @["x", "q"]

  test "a QuitMsg is not forwarded to update":
    let m = prog().runHeadless(@[Msg(QuitMsg()), Msg(key("x"))])
    check m.log.len == 0

suite "suspending":
  ## The intercept, and nothing about the signal — a test process that actually
  ## stopped itself would take the suite with it, which is exactly why
  ## `runHeadless` refuses. What is on the wire is `tests/manual/signals.py`'s.

  test "suspendCmd produces a SuspendMsg":
    let msg = suspendCmd()()
    check msg of SuspendMsg

  test "a SuspendMsg is not forwarded to update":
    # Runtime bookkeeping, like QuitMsg, BatchMsg and ScheduleMsg: intercepted in
    # `handle` and never seen by an application.
    let m = prog().runHeadless(@[Msg(SuspendMsg()), Msg(key("x"))])
    check m.log == @["x"]

  test "and headless does not stop the process that is testing it":
    # The assertion is that this returns at all. `suspend` is the one runtime
    # operation that is not reached through `p.terminal` — it is a kill on this
    # process — so the headless guard is the only thing between a test suite and
    # a stopped test suite.
    let m = prog().runHeadless(@[Msg(key("z")), Msg(key("x"))])
    check m.log == @["z", "x"]

suite "running another program":
  ## The intercept and the headless refusal. Whether the terminal actually
  ## changes hands is `tests/manual/signals.py`'s, which is the only place it
  ## can be: it needs a pty, a process group and a real child.

  test "execCmd produces an ExecMsg carrying the command":
    let msg = execCmd("git", ["commit", "-v"])()
    check msg of ExecMsg
    check ExecMsg(msg).command == "git"
    check ExecMsg(msg).args == @["commit", "-v"]

  test "an ExecMsg is not forwarded to update":
    # Runtime bookkeeping, like QuitMsg and SuspendMsg. A `then` returning nil,
    # so that what update sees is only what update should see — with no `then`
    # the refusal below arrives as an ErrorMsg, which *is* forwarded and is a
    # different claim.
    let quiet = execCmd("true", [], proc (r: ExecResult): Msg = nil)
    let m = prog().runHeadless(@[Msg(quiet()), Msg(key("x"))])
    check m.log == @["x"]

  test "headless runs no child but still answers":
    # Not silence: a state machine waiting on `then` would otherwise stall, and
    # the test would look like the program had hung rather than like the runtime
    # had declined. The refusal itself is the point — a test suite is not a thing
    # that should be spawning editors.
    var got: ExecResult
    var called = false
    let cmd = execCmd("true", [], proc (r: ExecResult): Msg =
      got = r
      called = true
      nil)
    discard prog().runHeadless(@[Msg(cmd())])
    check called
    check got.code == -1
    check got.error != nil

  test "and with no continuation the refusal arrives as an ErrorMsg":
    let m = prog().runHeadless(@[Msg(ExecMsg(command: "true"))])
    check m.log.len == 1
    check m.log[0].startsWith "error: "

suite "timers":
  test "scheduled messages are delivered":
    let m = prog().runHeadless(@[Msg(key("t"))])
    check m.ticks == 1

  test "internal ScheduleMsg never reaches update":
    let m = prog().runHeadless(@[Msg(after(initDuration(milliseconds = 1), PingMsg())())])
    check m.log == @["ping"]

  test "timers from initCmd are delivered with no messages at all":
    let m = prog(after(initDuration(milliseconds = 1), PingMsg())).runHeadless(@[])
    check m.log == @["ping"]

  test "timers from initCmd come before the first message":
    # `run` delivers them before any input arrives, so headless has to as well.
    let m = prog(after(initDuration(milliseconds = 1), PingMsg())).runHeadless(
      @[Msg(key("a"))])
    check m.log == @["ping", "a"]

  test "a timer scheduling another is delivered too":
    # The `after(DurationZero, …)` slicing pattern: each step queues the next.
    let m = chainProg().runHeadless(@[])
    check m.steps == 4

  test "a self-rearming timer stops at maxTimers rather than hanging":
    # `update` re-issuing `tick` is the documented way to repeat, so there is
    # never a point at which no timer is pending.
    check repeatProg().runHeadless(@[], maxTimers = 5).ticks == 5

  test "maxTimers is a budget for the whole run, not per message":
    let m = repeatProg().runHeadless(@[Msg(key("x")), Msg(key("y"))], maxTimers = 7)
    check m.ticks == 7

suite "runtime messages":
  test "window size is an ordinary message":
    let m = prog().runHeadless(@[Msg(WindowSizeMsg(width: 120, height: 40))])
    check m.log == @["size 120"]

  test "a paste is an ordinary message":
    # It arrives from the terminal like the runtime's own bookkeeping does, but
    # it is not intercepted in `handle` — it reaches `update` whole, newline and
    # all, which is the entire point of decoding it separately from keys.
    let m = prog().runHeadless(@[Msg(PasteMsg(text: "one\ntwo"))])
    check m.log == @["paste one\ntwo"]

suite "manual driving":
  test "send plus drain steps the program from outside the loop":
    let p = prog()
    p.send key("a")
    check p.drain()
    check p.model.count == 1
    p.send key("q")
    check not p.drain()

suite "mouse tracking options":
  ## The options are three points on one scale, and the mapping onto `tty`'s enum
  ## is where that has to be decided once. Nothing else here can be asserted
  ## without a terminal to enable a mouse on, which is why the proc takes the
  ## option set rather than the `Program`.

  test "no mouse option asks for no reporting":
    check {poAltScreen, poHideCursor}.mouseTracking().isNone

  test "each option maps to its own level":
    check {poMouseClicks}.mouseTracking() == some(mtClicks)
    check {poMouseCellMotion}.mouseTracking() == some(mtCellMotion)
    check {poMouseAllMotion}.mouseTracking() == some(mtAllMotion)

  test "the most detailed level wins rather than the first or the last":
    # Asking for clicks and all motion is asking for the superset. Resolving it
    # the other way would silently downgrade an app that added an option.
    check {poMouseClicks, poMouseAllMotion}.mouseTracking() == some(mtAllMotion)
    check {poMouseClicks, poMouseCellMotion}.mouseTracking() == some(mtCellMotion)
    check {poMouseCellMotion, poMouseAllMotion}.mouseTracking() == some(mtAllMotion)
    check {poMouseClicks, poMouseCellMotion,
           poMouseAllMotion}.mouseTracking() == some(mtAllMotion)

  test "the levels are ordered least to most, which the resolution relies on":
    check mtClicks < mtCellMotion
    check mtCellMotion < mtAllMotion

  test "clicks is a real option, not a synonym for off":
    # The bug this replaces: with only two motion levels to choose from, the
    # third state was spelled "leave the mouse off entirely".
    check {poMouseClicks}.mouseTracking().isSome

suite "the modes an option set puts the terminal into":
  ## Same reasoning as the suite above: split out of `setupTerminal` so that what
  ## it decides is assertable with no terminal to set a mode on.

  test "each option contributes its own mode":
    check tmAltScreen in {poAltScreen}.terminalModes()
    check tmHideCursor in {poHideCursor}.terminalModes()
    check tmMouse in {poMouseClicks}.terminalModes()
    check tmBracketedPaste in {poBracketedPaste}.terminalModes()
    check tmFocus in {poFocusReporting}.terminalModes()

  test "an option nothing asked for is not set":
    check tmAltScreen notin {poHideCursor}.terminalModes()
    check tmMouse notin {poAltScreen, poFocusReporting}.terminalModes()

  test "auto-wrap is off whatever the program asked for":
    # The one mode with no option behind it: the renderer's arithmetic assumes no
    # wrapping, so this is the library's decision and not the application's. A
    # program that set no options at all still gets it, which is the case that
    # would quietly regress if it were ever moved behind one.
    check tmLineWrap in {}.terminalModes()
    for o in ProgramOption:
      checkpoint $o
      check tmLineWrap in {o}.terminalModes()

  test "every mode a program can reach is one the teardown undoes":
    # `restoreEscapesFor` is what puts them back, and a mode set here with no
    # branch there is a terminal left changed. The assertion is indirect because
    # the two live in different modules on purpose.
    let all = {ProgramOption.low .. ProgramOption.high}.terminalModes()
    for m in all:
      checkpoint $m
      check restoreEscapesFor({m}).len > 0

type Sized = object       ## the `TermSize` convention in an actual update proc
  size: TermSize
  reflows: int

proc sizedUpdate(m: Sized, msg: Msg): (Sized, Cmd) =
  result = (m, nil)
  if result[0].size.handleResize(msg):
    result[0].reflows.inc                 # what the new size invalidated
  elif msg of KeyMsg and $KeyMsg(msg) == "q":
    result[1] = quitCmd()

suite "the resize branch as one line":
  ## `tcomponents` covers `handleResize` on its own; this is the shape an
  ## application copies, driven through the loop it will actually run under.

  test "the size reaches the model and the branch runs":
    let m = newProgram(Sized(), sizedUpdate, proc (s: Sized): string = $s.size.width)
      .runHeadless(@[Msg(WindowSizeMsg(width: 100, height: 30))])
    check m.size == TermSize(width: 100, height: 30)
    check m.reflows == 1

  test "the elif chain still sees everything else":
    # The trap in leading with `handleResize`: it has to return false for a key,
    # or the branch below it never runs and the program cannot be quit.
    let m = newProgram(Sized(), sizedUpdate, proc (s: Sized): string = $s.size.width)
      .runHeadless(@[Msg(WindowSizeMsg(width: 100, height: 30)),
                     Msg(KeyMsg(key: kRune, rune: "q".runeAt(0))),
                     Msg(WindowSizeMsg(width: 200, height: 60))])
    check m.reflows == 1                  # quit before the second resize
    check m.size == TermSize(width: 100, height: 30)
