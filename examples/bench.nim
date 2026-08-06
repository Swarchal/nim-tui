## A rendering stress test, with the numbers on screen.
##
## What this example is really about: **the renderer redraws lines, not frames**,
## so what a frame costs is decided by how much of it moved. Three scenes sit at
## the extremes of that, and the header reports what each one actually costs:
##
## * `plasma` — every cell a different truecolour pair, so nothing can be
##   skipped and the whole screen is rewritten every frame. The bytes figure is
##   the interesting one here: this is the scene that finds the ceiling of the
##   *terminal*, not of the library.
## * `firehose` — text scrolling as fast as the loop will go. Every line shifts,
##   so again nothing is skipped, but the lines are cheap.
## * `still` — a frame that never changes. Only the statistics line differs from
##   the previous frame, so the renderer writes one line however large the
##   terminal is.
##
## Flip between them and watch `lines` in the header: the frame rate is set by
## how many of them are rewritten, and by very little else. Uncapped over a
## 200x50 pty drained as fast as it is written:
##
## | scene | | |
## | --- | --- | --- |
## | `plasma`, truecolour | 112 fps | 40 MB/s |
## | `plasma`, 256 colours (`c`) | 309 fps | 32 MB/s |
## | `firehose` | 2110 fps | 27 MB/s |
## | `still` | 2792 fps | 1.3 MB/s |
##
## The last row is the one to read twice: the view is nine kilobytes and the
## renderer writes about four hundred bytes of it. The first two rows are the
## other lesson — at those rates the limit is what the terminal will swallow,
## not what the library will produce, and a terminal that repaints on the CPU
## will be the slowest part of the picture by a wide margin.
##
## Also shows: driving the loop as fast as it will go with
## `after(DurationZero, …)`, which is the same trick `indexer` uses for slow
## work — a command that re-issues itself with no delay, so the loop never
## blocks on input. **Uncapped, this spins a core**, which is the point of a
## benchmark and rude in anything else; `-` caps it.
##
##   nim c -r -d:release --path:src examples/bench.nim
##
## Build with `-d:release`. A debug build measures the compiler's bounds checks
## rather than the library.

import std/[math, strutils, strformat, times]
import nimtui

const
  RingSize = 120           ## frame intervals kept for the rolling average
  FpsCaps = [0, 240, 120, 60, 30, 15]   ## 0 = uncapped
  HalfBlock = "▀"          ## fg is the upper pixel, bg the lower: two rows per cell
  RampSize = 128

proc quantised(g: Gradient): seq[Color] =
  ## The same ramp through the xterm 256-colour cube.
  result = g.ramp(RampSize)
  for c in result.mitems: c = c.toAnsi256

const
  # Resolved at compile time — `color` emits no escape sequences and has no
  # dependencies, so a whole palette, quantisation and all, is a `const`.
  Ramps = [
    [RainbowGradient.ramp(RampSize), HeatGradient.ramp(RampSize),
     CoolGradient.ramp(RampSize), SunsetGradient.ramp(RampSize)],
    [RainbowGradient.quantised, HeatGradient.quantised,
     CoolGradient.quantised, SunsetGradient.quantised]]
  RampNames = ["rainbow", "heat", "cool", "sunset"]
  DepthNames = ["truecolour", "256"]

  Accent = rgb(120, 220, 200)
  Theme = DefaultTheme

type
  FrameMsg = ref object of Msg

  Scene = enum
    scPlasma = "plasma"
    scFirehose = "firehose"
    scStill = "still"

  Model = object
    scene: Scene
    palette: int
    depth: int             ## index into Ramps: truecolour or 256
    size: TermSize
    anim: float            ## animation clock in seconds, frozen while paused
    paused: bool
    cap: int               ## index into FpsCaps
    rate: int              ## firehose: lines pushed per frame
    frames: int
    scrolled: int
    lastAt: MonoTime
    ring: array[RingSize, int64]   ## recent frame intervals, nanoseconds
    at, filled: int
    sceneNs: int64         ## last reading of the probe below
    bytes, changed, total: int

# --- the probe ----------------------------------------------------------------
#
# Instrumentation, and the only mutable state outside the model. `view` writes
# it and never reads it, so `view` is still a pure function of the model — the
# same model gives the same string. `update` picks the readings up on the next
# frame, which is why the header lags the scene by one frame.
#
# A real view keeps no copy of the previous frame; the renderer already has one.
# This one does, to report how many lines differ — the same comparison the
# renderer makes, so the figure is the one it acts on.
#
# The loop renders on every iteration, not only on a `FrameMsg`, so a keypress
# arriving between frames has `view` run twice on the same model. The second run
# honestly reports zero lines changed — that is the frame the renderer skips
# outright — which is why the count blinks to 0 for an instant when a key is
# pressed during an animated scene.

var
  probeNs: int64
  probeBytes, probeChanged, probeTotal: int
  probePrev: string

proc sameLine(a: string, a0, a1: int, b: string, b0, b1: int): bool =
  ## Whether two line ranges hold the same bytes, without materialising either
  ## as a string. `renderer.sameLine` in miniature.
  if a1 - a0 != b1 - b0: return false
  if a1 == a0: return true
  equalMem(unsafeAddr a[a0], unsafeAddr b[b0], a1 - a0)

proc measure(frame: string) =
  var
    a = 0
    b = 0
    changed = 0
    total = 0
  while a <= frame.len:
    var aEnd = frame.find('\n', a)
    if aEnd < 0: aEnd = frame.len
    var bEnd = if b <= probePrev.len: probePrev.find('\n', b) else: -1
    if bEnd < 0: bEnd = probePrev.len
    let had = b <= probePrev.len and probePrev.len > 0
    if not (had and sameLine(frame, a, aEnd, probePrev, b, bEnd)): inc changed
    inc total
    if aEnd == frame.len: break
    a = aEnd + 1
    b = min(bEnd + 1, probePrev.len)
  probeChanged = changed
  probeTotal = total
  probePrev = frame

# --- scenes -------------------------------------------------------------------

proc rampIndex(v: float): int =
  ## Three summed sines land in [-3, 3]; map that onto the palette.
  clamp(((v + 3.0) * (RampSize - 1).float / 6.0).int, 0, RampSize - 1)

proc plasmaScene(m: Model, width, height: int): string =
  ## Every cell its own foreground and background colour.
  ##
  ## The three sine terms depend on `x`, on `y` and on `x + y`, so each is
  ## tabulated once per frame rather than evaluated per cell: at a hundred
  ## thousand cells a second the trigonometry would otherwise be the whole cost,
  ## and the point here is to measure the library rather than `sin`.
  if width <= 0 or height <= 0: return ""
  let rows = height * 2
  var
    cx = newSeq[float](width)
    cy = newSeq[float](rows)
    cd = newSeq[float](width + rows)
  for x in 0 ..< width: cx[x] = sin(x.float * 0.11 + m.anim * 1.9)
  for y in 0 ..< rows: cy[y] = sin(y.float * 0.09 + m.anim * 1.3)
  for d in 0 ..< width + rows: cd[d] = sin(d.float * 0.05 + m.anim * 0.7)

  let pal = Ramps[m.depth][m.palette]
  var lines = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let
      top = row * 2
      bot = top + 1
    var line: Spans
    line.items = newSeqOfCap[Span](width)
    for x in 0 ..< width:
      line.add(HalfBlock, Style()
        .fg(pal[rampIndex(cx[x] + cy[top] + cd[x + top])])
        .bg(pal[rampIndex(cx[x] + cy[bot] + cd[x + bot])]))
    # `render` coalesces neighbouring cells that share a style. In a smooth
    # truecolour field almost none do, so the line carries an escape sequence
    # per cell — which is why `c`, quantising the same ramp to 256 colours,
    # takes a bite out of the byte count rather than only out of the palette.
    lines.add line.render()
  lines.join("\n")

const
  Levels = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"]
  Workers = ["ingest-01", "ingest-02", "compact", "gc-worker", "flush-03"]
  Events = [
    "read 4096 rows from segment",
    "compacted 12 segments into 1",
    "flushed write buffer",
    "cache miss, falling back to disk",
    "lease renewed",
    "backpressure applied to producer",
    "checkpoint written",
    "replica caught up",
  ]

proc levelStyle(level: string): Style =
  case level
  of "ERROR": Theme.errorStyle
  of "WARN": Theme.warnStyle
  of "INFO": Theme.infoStyle
  of "DEBUG": Theme.mutedStyle
  else: Style().faint()

proc logLine(i, width: int): string =
  ## Line number `i` of an endless log. A function of `i` alone, so the scene
  ## needs no buffer and scrolling is just a moving window.
  let h = (i.uint32 * 2654435761'u32) shr 8
  let level = Levels[(h mod Levels.len.uint32).int]
  var s: Spans
  s.add(&"{i:>9}  ", Style().faint())
  s.add(&"{i.float * 0.0007:9.3f}s  ", Style().faint())
  s.add(padVisible(level, 6), level.levelStyle)
  s.add(padVisible(Workers[((h shr 5) mod Workers.len.uint32).int], 11),
        Theme.secondaryStyle)
  s.add(Events[((h shr 11) mod Events.len.uint32).int])
  s.add(&"  {(h mod 9000).int.float / 1000.0 + 0.1:.3f}ms", Style().faint())
  s.fit(width).render()

proc firehoseScene(m: Model, width, height: int): string =
  if width <= 0 or height <= 0: return ""
  var lines = newSeqOfCap[string](height)
  for i in max(m.scrolled - height + 1, 0) .. m.scrolled:
    lines.add logLine(i, width)
  lines.join("\n")

const StillText = """
Nothing on this card moves.

The renderer holds the lines it believes are on screen and compares each new
line against them, so a line equal to its predecessor is stepped over rather
than rewritten. Whatever the size of the terminal, this frame costs one line —
the statistics above, the only thing on screen that changes. Watch the `lines`
figure, and the gap between `KB view` and what that implies is written.

That is also why `ms/frame` here is not zero: `view` still builds the whole
frame every time round the loop, and the renderer still walks it. Building the
frame is the cost that is left, and it is the one to measure.
"""

proc stillScene(m: Model, width, height: int): string =
  if width <= 0 or height <= 0: return ""
  let
    cardW = min(width - 4, 72)
    inner = cardW - 4
  var body: seq[string]
  for para in StillText.strip.split("\n\n"):
    if body.len > 0: body.add ""
    for line in wrapText(para.replace("\n", " "), inner):
      body.add line
  let card = panel()
    .title(" a frame that does not change ", aCenter)
    .styled(border = Theme.borderStyle, title = Style().bold().fg(Accent))
    .pad(1)
    .render(body.join("\n"), cardW, min(body.len + 4, height))
  place(fillBlock("", Style(), width, height), card)

# --- update -------------------------------------------------------------------

proc frameCmd(cap: int): Cmd =
  ## The next frame, as soon as the cap allows.
  ##
  ## `DurationZero` means the loop's poll returns immediately, so frames are
  ## produced as fast as `update` and `view` can be run — the loop still
  ## interleaves input, which is what keeps the keys responsive at 2000 fps.
  if FpsCaps[cap] == 0: after(DurationZero, FrameMsg())
  else: after(initDuration(nanoseconds = 1_000_000_000 div FpsCaps[cap]),
              FrameMsg())

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)

  if msg of FrameMsg:
    let now = getMonoTime()
    let dt = (now - m.lastAt).inNanoseconds
    result[0].lastAt = now
    # The first interval spans start-up, not a frame, so it is not recorded.
    if m.frames > 0:
      result[0].ring[m.at] = dt
      result[0].at = (m.at + 1) mod RingSize
      result[0].filled = min(m.filled + 1, RingSize)
    result[0].frames = m.frames + 1
    if not m.paused:
      result[0].anim = m.anim + dt.float / 1e9
      result[0].scrolled = m.scrolled + m.rate
    result[0].sceneNs = probeNs
    result[0].bytes = probeBytes
    result[0].changed = probeChanged
    result[0].total = probeTotal
    result[1] = frameCmd(m.cap)

  elif msg of KeyMsg:
    # Nothing here issues a `frameCmd`: exactly one is in flight at any moment,
    # and a second chain started by a keypress would double the frame rate and
    # quietly halve every number on screen.
    template reset =
      result[0].frames = 0
      result[0].filled = 0
      result[0].at = 0
      result[0].lastAt = getMonoTime()

    case $KeyMsg(msg)
    of "q", "ctrl+c": result[1] = quitCmd()
    of "tab", "right":
      result[0].scene = Scene((m.scene.ord + 1) mod (Scene.high.ord + 1))
      reset()
    of "shift+tab", "left":
      result[0].scene = Scene((m.scene.ord + Scene.high.ord) mod
                              (Scene.high.ord + 1))
      reset()
    of "1":
      result[0].scene = scPlasma
      reset()
    of "2":
      result[0].scene = scFirehose
      reset()
    of "3":
      result[0].scene = scStill
      reset()
    of "space", "p": result[0].paused = not m.paused
    of "g": result[0].palette = (m.palette + 1) mod RampNames.len
    of "c": result[0].depth = (m.depth + 1) mod DepthNames.len
    of "-", "_":
      result[0].cap = min(m.cap + 1, FpsCaps.high)
      reset()
    of "+", "=":
      result[0].cap = max(m.cap - 1, 0)
      reset()
    of "]": result[0].rate = min(m.rate * 2, 64)
    of "[": result[0].rate = max(m.rate div 2, 1)
    of "r": reset()
    else: discard

# --- view ---------------------------------------------------------------------

proc intervals(m: Model): tuple[avg, worst: int64] =
  if m.filled == 0: return (0'i64, 0'i64)
  var total = 0'i64
  for i in 0 ..< m.filled:
    total += m.ring[i]
    result.worst = max(result.worst, m.ring[i])
  result.avg = total div m.filled

proc si(n: float, unit: string): string =
  ## `1.20 M px/s`, so a throughput fits in a header at any magnitude.
  # The plain case goes through `int`: `{x:5.0f}` leaves a trailing point in
  # Nim, so `111 lines/s` would print as `111. lines/s`.
  if n >= 1e9: &"{n / 1e9:5.2f} G {unit}"
  elif n >= 1e6: &"{n / 1e6:5.2f} M {unit}"
  elif n >= 1e3: &"{n / 1e3:5.2f} k {unit}"
  else: &"{n.round.int:5} {unit}"

proc header(m: Model, bodyH: int): string =
  let
    (avg, worst) = m.intervals
    fps = if avg > 0: 1e9 / avg.float else: 0.0
    cap = if FpsCaps[m.cap] == 0: "uncapped"
          else: &"capped {FpsCaps[m.cap]}"
    state = if m.paused: Theme.warnStyle.render("paused") else: cap
    tabs = tabBar([$scPlasma, $scFirehose, $scStill], m.scene.ord,
                  activeStyle = Style().bold().fg(Accent))
    right = &"{DepthNames[m.depth]}  {RampNames[m.palette]}  " &
            &"{m.size.width}x{m.size.height}  {state} "
    throughput =
      case m.scene
      of scPlasma: si(m.size.width.float * bodyH.float * 2.0 * fps, "px/s")
      of scFirehose: si(m.rate.float * fps, "lines/s")
      of scStill: si(m.changed.float * fps, "lines/s")

  var stats: Spans
  stats.add(&" {fps:8.1f}", Style().bold().fg(Accent))
  stats.add(" fps  ", Style().faint())
  stats.add(&"{avg.float / 1e6:6.2f}", Style().bold())
  stats.add(&" ms/frame (worst {worst.float / 1e6:6.2f})  ", Style().faint())
  stats.add(&"{m.sceneNs.float / 1000.0:8.1f}", Style().bold())
  stats.add(" µs scene  ", Style().faint())
  # The size of the string `view` returned, not of what was written: the
  # renderer sends only the lines counted to the right of it.
  stats.add(&"{m.bytes.float / 1024.0:7.1f}", Style().bold())
  stats.add(" KB view  ", Style().faint())
  # The figure the rest of this example exists to make visible.
  stats.add(&"{m.changed}/{m.total}", Style().bold().fg(
    if m.total > 0 and m.changed * 4 < m.total: Theme.success else: Theme.warn))
  stats.add(" lines  ", Style().faint())
  stats.add(throughput, Style().bold())

  joinVertical(
    statusBar(Style().bold().render(" nimtui bench ") & " " & tabs, "",
              right, m.size.width),
    stats.fit(m.size.width).render())

proc view(m: Model): string =
  if m.size.width == 0 or m.size.height < 8: return "sizing…"
  let bodyH = m.size.height - 3

  # Only the scene is timed. The header is a dozen small strings whichever
  # scene is showing, so including it would blur the thing being compared.
  let t0 = getMonoTime()
  let body =
    case m.scene
    of scPlasma: m.plasmaScene(m.size.width, bodyH)
    of scFirehose: m.firehoseScene(m.size.width, bodyH)
    of scStill: m.stillScene(m.size.width, bodyH)
  probeNs = (getMonoTime() - t0).inNanoseconds

  result = joinVertical(m.header(bodyH), body,
    " " & hints({"tab": "scene", "space": "pause", "g": "palette",
                 "c": "depth", "+/-": "cap", "[/]": "rate", "r": "reset",
                 "q": "quit"}))
  probeBytes = result.len
  measure(result)

when isMainModule:
  let model = Model(scene: scPlasma, rate: 1, lastAt: getMonoTime())
  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor},
                     initCmd = frameCmd(model.cap)).run()
