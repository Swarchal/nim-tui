## Long-running work without blocking the UI.
##
## What this example is really about: the answer to "my command takes two
## seconds and the app freezes". Commands run synchronously between updates, so
## a slow one blocks rendering and input for as long as it runs — and there is
## no threadpool to escape to (see `tests/manual/orc_closure_threads.nim` for
## why). The fix is to make the work re-entrant: do a *bounded slice*, return a
## message, and re-issue `after(DurationZero, …)`. The loop delivers input and
## redraws between slices, so the spinner keeps turning and the list keeps
## scrolling while several hundred thousand units of work go by.
##
## The two things that make it work, both easy to get wrong:
##
## * **The slice has to be bounded by work, not by time-since-start.** A slice
##   that keeps going "until 16ms have passed" is still one long command as far
##   as the loop is concerned if the clock check is wrong; a fixed unit count is
##   simply correct.
## * **A generation counter, or restarting leaks a chain.** Pressing `r` while a
##   chain is in flight starts a second one, and both then run — twice the work
##   per frame and a progress bar that jumps backwards. `snake.nim` guards its
##   tick the same way, for the same reason.
##
## Also shows `runHeadless`, which is how you test an update proc like this one
## without a terminal: `./indexer --selftest`.
##
##   nim c -r --path:src examples/indexer.nim

import std/[os, times, strutils, strformat, unicode]
import nimtui

const
  Total = 6_000_000      ## units of work in a full run — a few seconds of it
  SliceSize = 6_000      ## units per slice — the whole trick is that this is bounded
                         ## Sized so a slice costs a few milliseconds: small enough
                         ## that input never waits noticeably, large enough that the
                         ## per-slice message round trip is not the dominant cost.
  Corpus = ["src/nimtui.nim", "src/nimtui/ansi.nim", "src/nimtui/color.nim",
            "src/nimtui/layout.nim", "src/nimtui/spans.nim",
            "src/nimtui/table.nim", "src/nimtui/theme.nim",
            "src/nimtui/widgets.nim", "src/nimtui/textarea.nim",
            "src/nimtui/listview.nim", "src/nimtui/renderer.nim",
            "src/nimtui/program.nim"]

type
  WorkMsg = ref object of Msg
    gen: int             ## which run this slice belongs to
  SpinMsg = ref object of Msg

  Model = object
    done: int
    gen: int
    running: bool
    checksum: uint32
    log: seq[string]
    list: ListView
    frame: int
    width, height: int
    started, finished: MonoTime
    theme: Theme

proc workCmd(gen: int): Cmd =
  ## `DurationZero`, so the next slice is due immediately — this is a yield to
  ## the event loop, not a delay. Anything already queued (a keypress, a resize)
  ## is handled before the slice runs.
  after(DurationZero, WorkMsg(gen: gen))

proc spinCmd(): Cmd = after(initDuration(milliseconds = 80), SpinMsg())

proc grind(seed: uint32, rounds: int): uint32 =
  ## Stands in for real work. Deliberately not optimised away: the point of the
  ## example is that this genuinely costs something.
  result = seed
  for i in 0 ..< rounds:
    # Unsigned arithmetic wraps in Nim, which is what a mixing step wants.
    result = result * 1664525'u32 + 1013904223'u32
    result = result xor (result shr 15)

proc elapsed(m: Model): Duration =
  (if m.running: getMonoTime() else: m.finished) - m.started

proc restart(m: var Model) =
  m.done = 0
  m.checksum = 0
  m.log.setLen 0
  m.list.sync 0
  m.running = true
  m.started = getMonoTime()
  m.gen.inc                  # invalidates any slice still in flight

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of SpinMsg:
    result[0].frame.inc
    result[1] = spinCmd()

  elif msg of WorkMsg:
    # A slice from a previous run: drop it and, crucially, do not re-issue. That
    # is what stops the old chain rather than merely ignoring its results.
    if WorkMsg(msg).gen != m.gen: return
    if not m.running: return

    let units = min(SliceSize, Total - m.done)
    result[0].checksum = grind(m.checksum + m.done.uint32, units)
    result[0].done += units

    # Log a "file" every so often, so there is something to scroll while it runs.
    let before = m.done * Corpus.len div Total
    let after = result[0].done * Corpus.len div Total
    if after > before and before < Corpus.len:
      result[0].log.add &"{Corpus[before]}  ({result[0].checksum:08x})"

    if result[0].done >= Total:
      result[0].running = false
      result[0].finished = getMonoTime()
    else:
      result[1] = workCmd(m.gen)

  elif msg of WindowSizeMsg:
    result[0].width = WindowSizeMsg(msg).width
    result[0].height = WindowSizeMsg(msg).height
    result[0].list.vp.height = max(result[0].height - 12, 1)
    result[0].list.sync result[0].log.len

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    if result[0].list.handleKey(k, m.log.len): return
    case $k
    of "q", "ctrl+c": result[1] = quitCmd()
    of "space", "p":
      if m.done < Total:
        result[0].running = not m.running
        # Resuming restarts the chain; pausing simply lets it stop, because the
        # `not running` branch above returns without re-issuing.
        if result[0].running: result[1] = workCmd(m.gen)
    of "r":
      result[0].restart()
      result[1] = workCmd(result[0].gen)
    else: discard

# --- view ---------------------------------------------------------------------

proc view(m: Model): string =
  if m.width == 0: return "loading…"
  let
    t = m.theme
    w = m.width
    frac = m.done / Total
    secs = m.elapsed.inMilliseconds.float / 1000.0
    rate = if secs > 0.01: m.done.float / secs else: 0.0

  let state =
    if m.done >= Total: t.successStyle.render("✓ complete")
    elif m.running: t.accentStyle.render(spinner(m.frame) & " indexing")
    else: t.warnStyle.render("⏸ paused")

  let header = statusBar(
    " " & gradientText("indexer", t.ramp, Style().bold()) & "  " & state, "",
    t.mutedStyle.render(&"{secs:5.1f}s · {rate.int} units/s "), w)

  var rows: seq[string]
  rows.add ""
  rows.add gauge(frac, max(w - 4, 4), t.ramp)
  rows.add ""
  rows.add span(&"{m.done} / {Total} units", t.mutedStyle).render() &
           span(&"   {frac * 100:5.1f}%", t.accentStyle).render() &
           span(&"   slice {SliceSize}   checksum {m.checksum:08x}",
                t.mutedStyle).render()

  let progress = panel(RoundedBorder)
    .title(" progress ")
    .pad(1)
    .styled(border = t.borderStyle, title = t.titleStyle)
    .render(rows.join("\n"), w, 8)

  let listHeight = max(m.height - 10, 3)
  let body = panel(RoundedBorder)
    .title(" indexed ")
    .footer(if m.log.len == 0: " nothing yet " else: &" {m.log.len} files ")
    .pad(1)
    .styled(border = t.borderStyle, title = t.titleStyle, footer = t.mutedStyle)
    .render(m.list.render(m.log, max(w - 4, 4),
                          selectedStyle = t.selectionStyle,
                          scrollbarStyle = t.mutedStyle),
            w, listHeight)

  let footer = " " & hints({"space": "pause", "r": "restart",
                            "↑↓": "scroll while it works", "q": "quit"})
  joinVertical(header, progress, body, footer)

# --- headless self-test -------------------------------------------------------

proc selfTest() =
  ## The same `update` driven with no terminal at all.
  ##
  ## `runHeadless` delivers timers immediately and in scheduled order, so a
  ## chain of `after(DurationZero, …)` slices runs to completion deterministically
  ## — which is exactly what makes this pattern testable. `maxTimers` has to
  ## cover the whole chain plus the spinner; it is a budget, and a run that hits
  ## it comes back at a suspiciously round number rather than hanging.
  let slices = (Total + SliceSize - 1) div SliceSize
  var model = Model(theme: DefaultTheme, running: true, started: getMonoTime())
  model.list = initListView(height = 10)

  let p = newProgram(model, update, view, initCmd = workCmd(0))
  let final = p.runHeadless(@[], maxTimers = slices + 16)

  doAssert final.done == Total, &"indexed {final.done}, expected {Total}"
  doAssert not final.running, "should have stopped on its own"
  doAssert final.log.len == Corpus.len, &"logged {final.log.len} files"
  echo &"ok — {final.done} units over {slices} slices, log {final.log.len} files"

  # The generation guard is a property of `update` alone, so test it by calling
  # `update` — it is an ordinary pure function, and reaching for the loop to
  # exercise one branch of it only makes the test harder to read.
  #
  # It also cannot be tested through `runHeadless` the obvious way: timers are
  # delivered *before* the first message, so a chain started by `initCmd` has
  # already run to completion by the time a keypress lands. There is no
  # "mid-flight" to interrupt.
  var mid = Model(theme: DefaultTheme, running: true, done: 60_000, gen: 3)
  mid.list = initListView(height = 10)

  let (stale, staleCmd) = update(mid, WorkMsg(gen: 2))
  doAssert stale.done == 60_000, "a stale slice must not do work"
  doAssert staleCmd == nil, "a stale slice must not re-issue, or the chain lives on"

  let (fresh, freshCmd) = update(mid, WorkMsg(gen: 3))
  doAssert fresh.done == 60_000 + SliceSize, "the current generation should work"
  doAssert freshCmd != nil, "and should keep the chain going"
  echo "ok — a slice from a superseded run does no work and starts no successor"

  # Restarting bumps the generation, which is what makes the above bite.
  let (restarted, _) = update(mid, KeyMsg(key: kRune, rune: "r".runeAt(0)))
  doAssert restarted.gen == 4, &"expected generation 4, got {restarted.gen}"
  doAssert restarted.done == 0
  echo "ok — restart bumps the generation"

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--selftest":
    selfTest()
    quit(0)
  var model = Model(theme: DefaultTheme, running: true, started: getMonoTime())
  model.list = initListView()
  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor},
                     initCmd = batch(workCmd(0), spinCmd())).run()
