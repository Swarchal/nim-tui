## The runtime: an Elm-style event loop over a user-supplied model.
##
## An application supplies three things:
##
## * a model — any type, treated as a value
## * `update(model, msg) -> (model, Cmd)` — the only place state changes
## * `view(model) -> string` — a pure render of the model
##
## The loop is single-threaded. Commands run synchronously between updates, so
## a slow command blocks rendering; time-based work is expressed with `after` /
## `tick`, which the loop schedules rather than sleeping on. See the module
## docs for the extension point if you need genuinely concurrent effects.

import std/[monotimes, times, algorithm]
import ./[ansi, messages, input, renderer, style, tty, query]

type
  UpdateProc*[M] = proc (model: M, msg: Msg): (M, Cmd) {.closure.}
  ViewProc*[M] = proc (model: M): string {.closure.}

  ProgramOption* = enum
    poAltScreen          ## draw on the alternate screen buffer
    poHideCursor         ## hide the cursor for the duration of the program
    poMouseCellMotion    ## report mouse motion while a button is held
    poMouseAllMotion     ## report all mouse motion
    poQueryBackground    ## ask the terminal its background colour at startup
    poBracketedPaste
      ## Ask the terminal to bracket pasted text, so a paste arrives as one
      ## `PasteMsg` instead of as its characters typed one at a time.
      ##
      ## Opt-in, and the contract is the same as the mouse options: **handle
      ## `PasteMsg` or pasted text is discarded.** Without the option a pasted
      ## newline arrives as `kEnter`, which submits a form halfway through the
      ## paste; with it and no handler, the paste is silently dropped instead.
      ## Neither is a default worth imposing, so the choice is the program's.

  Program*[M] = ref object
    model*: M
    update*: UpdateProc[M]
    view*: ViewProc[M]
    initCmd*: Cmd
    options*: set[ProgramOption]
    escTimeoutMs*: int   ## how long a lone ESC waits for a sequence to finish
    idleTimeoutMs*: int  ## upper bound on how long the loop blocks on input
    pasteTimeoutMs*: int
      ## How long a paste with no end marker is held before being delivered as
      ## it stands. A *stall* timeout — it measures the gap since the last byte
      ## arrived, not the length of the paste — so a slow but progressing paste
      ## is never cut off however long it takes.
      ##
      ## Far longer than `escTimeoutMs` because it is bounding something else
      ## entirely: an escape sequence that has paused for 50 ms is over, whereas
      ## a paste that has paused for 50 ms is ordinary. Raise it on a very slow
      ## link.
    detectColor*: bool
      ## Resolve the colour profile from `NO_COLOR`, `$COLORTERM` and `$TERM` at
      ## startup. Set false to keep whatever `style.setColorProfile` was given.
      ##
      ## A bool rather than an optional profile because `cpNoColor` is a
      ## legitimate forced value and so cannot double as "unset".
    terminalBg*: Color
      ## What `poQueryBackground` found, or `ckDefault`. The same value that went
      ## out as a `TerminalBgMsg`, kept for a caller that reads the program back
      ## after `run` returns rather than storing it in the model.
    renderer: Renderer
    terminal: Tty
    queue: seq[Msg]
    pending: seq[Cmd]
    timers: seq[ScheduleMsg]
    running: bool
    lastSize: tuple[width, height: int]

const
  DefaultEscTimeoutMs = 50
  DefaultIdleTimeoutMs = 250
  DefaultPasteTimeoutMs = 2000
    ## Above the worst inter-read gap inside a real paste — a bad link, or tmux
    ## relaying a large buffer — and below the point at which someone decides the
    ## program has hung and reaches for another terminal.

proc newProgram*[M](model: M, update: UpdateProc[M], view: ViewProc[M],
                    options: set[ProgramOption] = {},
                    initCmd: Cmd = nil): Program[M] =
  ## Create a program. Nothing touches the terminal until `run`.
  Program[M](model: model, update: update, view: view, initCmd: initCmd,
             options: options, escTimeoutMs: DefaultEscTimeoutMs,
             idleTimeoutMs: DefaultIdleTimeoutMs,
             pasteTimeoutMs: DefaultPasteTimeoutMs, detectColor: true)

proc send*[M](p: Program[M], msg: Msg) =
  ## Queue a message for delivery on the next loop iteration.
  if msg != nil: p.queue.add msg

proc enqueue[M](p: Program[M], cmd: Cmd) =
  if cmd != nil: p.pending.add cmd

proc handle[M](p: Program[M], msg: Msg): bool =
  ## Apply one message. Returns false when the program should stop.
  ##
  ## Runtime bookkeeping messages are intercepted here and never reach `update`.
  if msg of QuitMsg:
    return false
  if msg of BatchMsg:
    for c in BatchMsg(msg).cmds: p.enqueue c
    return true
  if msg of ScheduleMsg:
    p.timers.add ScheduleMsg(msg)
    # Compare ticks: `cmp` on MonoTime does not resolve through generic
    # instantiation from the caller's module.
    p.timers.sort(proc (a, b: ScheduleMsg): int =
      cmp(a.dueAt.ticks, b.dueAt.ticks))
    return true
  let (model, cmd) = p.update(p.model, msg)
  p.model = model
  p.enqueue cmd
  true

proc runCmds[M](p: Program[M]) =
  ## Drain the command queue, feeding results back into the message queue.
  ## Commands may enqueue further commands; this runs until quiescent.
  while p.pending.len > 0:
    let cmd = p.pending[0]
    p.pending.delete 0
    var produced: Msg
    try:
      produced = cmd()
    except CatchableError as e:
      produced = ErrorMsg(error: e)
    if produced != nil: p.queue.add produced

proc drain*[M](p: Program[M]): bool =
  ## Process every queued message and command. Returns false if a `QuitMsg` was
  ## seen. Exposed for tests and for embedding the loop in another event system.
  result = true
  while p.queue.len > 0 or p.pending.len > 0:
    while p.queue.len > 0:
      let msg = p.queue[0]
      p.queue.delete 0
      if not p.handle(msg):
        return false
    p.runCmds()

proc dueTimers[M](p: Program[M], now: MonoTime) =
  ## Move any elapsed timers' payloads onto the message queue.
  var keep: seq[ScheduleMsg]
  for t in p.timers:
    if t.dueAt <= now: p.queue.add t.payload
    else: keep.add t
  p.timers = keep

proc nextTimeoutMs[M](p: Program[M], now: MonoTime, buffered: bool): int =
  ## How long the loop may block: until the next timer, capped by the idle
  ## timeout, and shortened while a possibly-incomplete escape sequence is held.
  ##
  ## A held *paste* deliberately does not count as buffered. It is not waiting on
  ## an escape flush, it is waiting on bytes — which wake the poll on their own —
  ## so treating it as one would spin the loop at 20 Hz rescanning a payload that
  ## has not changed, for as long as the paste lasts.
  result = p.idleTimeoutMs
  if p.timers.len > 0:
    let ms = (p.timers[0].dueAt - now).inMilliseconds.int
    result = min(result, max(ms, 0))
  if buffered:
    result = min(result, p.escTimeoutMs)

proc deliverTimers[M](p: Program[M], budget: var int): bool =
  ## Deliver scheduled timers, earliest first, until none are left or `budget` is
  ## spent. Returns false if the program quit.
  ##
  ## Which timer is earliest is re-decided each time round, not snapshotted:
  ## delivering one timer can schedule another that falls due before a timer
  ## already waiting.
  while p.timers.len > 0 and budget > 0:
    let t = p.timers[0]
    p.timers.delete 0
    dec budget
    p.send t.payload
    if not p.drain(): return false
  true

proc runHeadless*[M](p: Program[M], msgs: openArray[Msg], maxTimers = 256): M =
  ## Run the update loop over a fixed list of messages with no terminal.
  ##
  ## Timers are delivered immediately in scheduled order rather than waited on,
  ## so tests stay deterministic. Returns the final model.
  ##
  ## There being no terminal, `poQueryBackground` does nothing here: a test that
  ## wants to exercise what its `TerminalBgMsg` leads to should put one in `msgs`,
  ## which is also the only way to test the case where the terminal declined.
  ## `detectColor` is likewise ignored — the colour profile stays whatever it
  ## was, so a test asserting on rendered bytes is not at the mercy of the
  ## environment it runs under.
  ##
  ## `maxTimers` bounds how many timer payloads are delivered across the whole
  ## run. The bound cannot be dispensed with: an `update` that re-issues `tick`
  ## when it fires — the documented way to repeat — is never out of timers, so
  ## draining until empty would never return. Set it to the number of ticks the
  ## test wants. The default is high enough for a chain of
  ## `after(DurationZero, …)` work slices and low enough that a repeating timer
  ## stops promptly; a test that hits it sees a suspiciously round number rather
  ## than hanging.
  var budget = maxTimers
  p.enqueue p.initCmd
  if not p.drain(): return p.model
  # Before the messages, not after the first one: in `run`, whatever `initCmd`
  # schedules comes due before any input arrives.
  if not p.deliverTimers(budget): return p.model
  for msg in msgs:
    p.send msg
    if not p.drain(): return p.model
    if not p.deliverTimers(budget): return p.model
  p.model

proc setupTerminal[M](p: Program[M]) =
  p.terminal.enterRawMode()
  # Immediately after raw mode and before any of the modes below, so the window
  # in which a terminating signal finds the terminal broken and no way to fix it
  # is a few instructions rather than the whole of startup. Arming the full
  # teardown before the modes are set is safe: turning off a mouse that was never
  # turned on is a no-op, as is leaving an alt screen never entered.
  p.terminal.armRestore(
    altScreen = poAltScreen in p.options,
    hideCursor = poHideCursor in p.options,
    mouse = poMouseCellMotion in p.options or poMouseAllMotion in p.options,
    bracketedPaste = poBracketedPaste in p.options)
  if poAltScreen in p.options: p.terminal.enterAltScreen()
  if poHideCursor in p.options: p.terminal.hideCursor()
  if poMouseAllMotion in p.options: p.terminal.enableMouse(allMotion = true)
  elif poMouseCellMotion in p.options: p.terminal.enableMouse()
  if poBracketedPaste in p.options: p.terminal.enableBracketedPaste()

proc restoreTerminal[M](p: Program[M]) =
  # The same bytes a terminating signal writes, minus what only a signal needs —
  # see `tty.emergencyEscapesFor`. Both go through `restoreEscapesFor`, so the
  # normal path and the handler cannot drift apart.
  p.terminal.restoreModes(
    altScreen = poAltScreen in p.options,
    hideCursor = poHideCursor in p.options,
    mouse = poMouseCellMotion in p.options or poMouseAllMotion in p.options,
    bracketedPaste = poBracketedPaste in p.options)
  # Only the renderer knows whether a block is on screen to move past, which is
  # exactly what a handler cannot ask it — hence the unconditional newline there.
  if poAltScreen notin p.options: p.renderer.finish()
  p.terminal.exitRawMode()

proc syncSize[M](p: Program[M]) =
  ## Re-read the terminal size. A stray SIGWINCH that reports the same size is
  ## ignored, so applications only see real changes.
  ##
  ## The old frame has to be cleared, not just forgotten: the terminal reflows
  ## on a resize, so the next frame would otherwise be drawn on top of a block
  ## it no longer matches, leaving the tail of the old one behind.
  let size = p.terminal.windowSize()
  if size == p.lastSize: return
  p.lastSize = size
  if poAltScreen in p.options:
    # The program owns the screen, so clearing all of it is exact even when the
    # old lines wrapped as the width shrank.
    p.terminal.write cursorTo(1, 1) & Reset & EraseDown
    p.renderer.repaint()
  else:
    # The block sits in the scrollback, so only the block may be erased.
    p.renderer.clearBlock()
  p.renderer.width = size.width
  p.renderer.height = size.height
  p.send WindowSizeMsg(width: size.width, height: size.height)

proc run*[M](p: Program[M], input = stdin, output = stdout): M =
  ## Take over the terminal and run until a command returns `QuitMsg`.
  ##
  ## Restores the terminal on any exit path, including exceptions. Returns the
  ## final model so callers can print a summary afterwards.
  p.terminal = initTty(input, output)
  if not p.terminal.isTerminal():
    raise newException(IOError,
      "nimtui: stdin/stdout is not a terminal; use runHeadless for tests")
  p.renderer = initRenderer(output)
  p.running = true

  watchResize()
  # Unconditional, like `watchResize` above and for the same reason: this is not
  # a feature but repair of damage the library itself does by clearing ECHO and
  # ICANON, and the person who most needs it is the one who did not know to ask.
  watchTerminate()
  p.setupTerminal()
  try:
    # Before the query, before the first size and before `initCmd`: both of those
    # may build styled strings, and a theme derived from the background colour
    # has to be assembled under the profile it will be drawn with.
    if p.detectColor: setColorProfile detectColorProfile()

    # Bytes read but not yet decoded. Declared before the query rather than
    # inside the loop because the query reads from the same stream and may pick
    # up a keystroke on the way: those belong to the loop, not to the answer.
    var buf = ""
    # When the last byte arrived, which is what `pasteTimeoutMs` measures from.
    # Not when the paste started: a paste held across several reads consumes
    # nothing each time, so timing from the start would cut a legitimate
    # three-second paste off at two.
    var lastByteAt = getMonoTime()

    if poQueryBackground in p.options:
      # Here and nowhere else. The question needs raw mode, so it cannot be asked
      # before `setupTerminal`; the answer has to be in the model before the first
      # frame, so it cannot be asked after the render below. Between the two, this
      # is the only owner of the input stream — which is what makes asking safe at
      # all, rather than a race with the decoder for the same bytes.
      p.terminalBg = queryBackground(p.terminal, buf)
      p.send TerminalBgMsg(color: p.terminalBg)

    p.syncSize()
    p.enqueue p.initCmd
    if not p.drain(): return p.model
    p.renderer.render p.view(p.model)

    while p.running:
      let now = getMonoTime()
      let holding = buf.holdsPaste()
      let event = p.terminal.waitForInput(
        p.nextTimeoutMs(now, buf.len > 0 and not holding))
      let timedOut = event == ieTimeout

      if takeResizePending():
        p.syncSize()

      case event
      of ieReadable:
        # A readable fd with nothing to read means the stream ended; stopping
        # here is what keeps a closed stdin from spinning the loop.
        if not p.terminal.readAvailable(buf): p.send QuitMsg()
        else: lastByteAt = getMonoTime()
      of ieClosed:
        p.send QuitMsg()
      of ieTimeout, ieInterrupted: discard

      if buf.len > 0:
        let stalled = holding and timedOut and
          (getMonoTime() - lastByteAt).inMilliseconds.int >= p.pasteTimeoutMs
        let (msgs, consumed) =
          parseInput(buf, flushEsc = timedOut, flushPaste = stalled)
        if consumed > 0: buf = buf[consumed .. ^1]
        for m in msgs: p.send m

      p.dueTimers(getMonoTime())

      if p.queue.len > 0 or p.pending.len > 0:
        if not p.drain():
          p.running = false
          break
      p.renderer.render p.view(p.model)
  finally:
    p.restoreTerminal()
  p.model
