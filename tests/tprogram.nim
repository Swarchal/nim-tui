import std/[unittest, times, unicode, options]
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
