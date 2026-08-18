## A live metrics dashboard.
##
## What this example is really about: several independent timers at different
## rates. Each one is a distinct message type that re-issues its own `after`
## when it fires, so the loop carries three concurrent schedules — a 90ms
## spinner, a 400ms metric sample and a 1.2s log line — without threads and
## without any of them blocking the others. The batched `initCmd` starts all
## three at once.
##
## Also shows: a layout that reflows from a 2x2 grid to a single column when the
## terminal is narrow — with the columns divided by `splitWidths`, so the panes
## come to exactly the terminal's width at every size — and history kept in the
## model so `view` stays pure.
##
##   nim c -r --path:src examples/dashboard.nim

import std/[random, math, strutils, times, strformat]
import nimtui

const
  SpinInterval = initDuration(milliseconds = 90)
  SampleInterval = initDuration(milliseconds = 400)
  LogInterval = initDuration(milliseconds = 1200)
  History = 120
  LogLines = 40

type
  SpinTickMsg = ref object of Msg
  SampleTickMsg = ref object of Msg
  LogTickMsg = ref object of Msg

  Series = object
    label: string
    values: seq[float]
    unit: string
    colour: Color

  LogEntry = object
    level: string
    text: string
    elapsed: Duration

  Model = object
    series: seq[Series]
    logs: seq[LogEntry]
    frame: int
    samples: int
    paused: bool
    started: MonoTime
    size: TermSize

# --- fake data ----------------------------------------------------------------

var rng = initRand(0x5eed)

proc nextValue(s: Series): float =
  ## Random walk with mean reversion, so the sparklines look like metrics
  ## rather than noise.
  let last = if s.values.len == 0: 50.0 else: s.values[^1]
  let drift = (50.0 - last) * 0.08
  clamp(last + drift + rng.gauss(0.0, 7.0), 0.0, 100.0)

const LogTemplates = [
  ("info", "GET /api/items 200"),
  ("info", "cache hit ratio 0.94"),
  ("warn", "slow query 812ms"),
  ("info", "worker heartbeat ok"),
  ("error", "upstream timeout, retrying"),
  ("info", "flushed 240 events"),
  ("warn", "queue depth 1204"),
]

# --- update -------------------------------------------------------------------

proc spin(): Cmd = after(SpinInterval, SpinTickMsg())
proc sample(): Cmd = after(SampleInterval, SampleTickMsg())
proc logTick(): Cmd = after(LogInterval, LogTickMsg())

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)

  if msg of SpinTickMsg:
    result[0].frame.inc
    result[1] = spin()                      # each timer re-arms itself

  elif msg of SampleTickMsg:
    if not m.paused:
      for i in 0 .. result[0].series.high:
        result[0].series[i].values.add result[0].series[i].nextValue
        if result[0].series[i].values.len > History:
          result[0].series[i].values.delete 0
      result[0].samples.inc
    result[1] = sample()

  elif msg of LogTickMsg:
    if not m.paused:
      let (level, text) = LogTemplates[rng.rand(LogTemplates.high)]
      result[0].logs.add LogEntry(level: level, text: text,
                                  elapsed: getMonoTime() - m.started)
      if result[0].logs.len > LogLines: result[0].logs.delete 0
    result[1] = logTick()

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("space", "p"): result[0].paused = not m.paused
    elif k.matches("r"):
      for i in 0 .. result[0].series.high:
        result[0].series[i].values.setLen 0
      result[0].logs.setLen 0
      result[0].samples = 0
      result[0].started = getMonoTime()

# --- view ---------------------------------------------------------------------

const
  Accent = rgb(120, 220, 200)
  # The gauges' track. A colour rather than the terminal's own background,
  # because the fractional cell at the end of a bar is a glyph over *this* — with
  # no track colour that cell's remainder is terminal background and the bar
  # appears to stop short of its own track by up to seven eighths of a cell.
  TrackColour = rgb(48, 52, 64)
  WarnColour = rgb(250, 200, 90)
  ErrorColour = rgb(255, 110, 110)

proc levelStyle(level: string): Style =
  case level
  of "warn": Style().fg(WarnColour)
  of "error": Style().fg(ErrorColour).bold()
  else: Style().faint()

proc seriesPane(s: Series, width, height: int): string =
  let inner = width - 4
  let cur = if s.values.len == 0: 0.0 else: s.values[^1]
  var lo = 100.0
  var hi = 0.0
  for v in s.values:
    lo = min(lo, v)
    hi = max(hi, v)
  if s.values.len == 0:
    lo = 0.0
    hi = 0.0

  let big = Style().bold().fg(s.colour).render(&"{cur:5.1f}") &
            Style().faint().render(s.unit)
  # `{x:.0f}` leaves a trailing point in Nim, hence the explicit int.
  let range = Style().faint().render(&"min {lo.round.int}  max {hi.round.int}")
  var rows = @["", "  " & big & "   " & range, ""]
  # A fixed 0-100 scale keeps the chart comparable between panels and stops it
  # rescaling every sample.
  # The style goes *in* rather than being applied to the finished row: the widget
  # is then able to paint a whole cell with the colour as its background instead
  # of drawing `█` in it, which is what keeps the bar from being striped by the
  # hairline many fonts leave at the edge of a block glyph.
  for line in barChart(s.values, inner, max(height - 2 - rows.len - 1, 1),
                       Style().fg(s.colour), lo = 0.0, hi = 100.0):
    rows.add "  " & line
  rows.add ""
  renderBox(rows.join("\n"), width, height, title = s.label,
            borderStyle = Style().faint(), titleStyle = Style().fg(s.colour))

proc gaugePane(m: Model, width, height: int): string =
  let inner = width - 4
  var rows = @[""]
  for s in m.series:
    let cur = if s.values.len == 0: 0.0 else: s.values[^1]
    let label = padVisible(s.label, 10)
    let barWidth = max(inner - 10 - 8, 4)
    # A one-stop gradient, which is how a single colour is said to the overload
    # that takes a track: both halves of every filled cell sample to `s.colour`,
    # so the cell is painted flat and the bar is the same one colour it was.
    #
    # A *solid* track, not `░` over one: the fractional cell at the end of the bar
    # is a glyph over the track's background, while a `░` track reads as that
    # background plus the dots — lighter — so the two would meet at a visibly
    # darker step. `░` only when there is no colour to paint with, since a
    # background paints nothing under `NO_COLOR` and the track would vanish.
    let (trackGlyph, trackStyle) =
      if colorProfile() == cpNoColor: ("░", Style().faint())
      else: (" ", Style().bg(TrackColour))
    rows.add "  " & Style().faint().render(label) &
             gauge(cur / 100.0, barWidth, gradient(s.colour),
                   empty = trackGlyph, emptyStyle = trackStyle) &
             &" {cur:5.1f}"
  renderBox(rows.join("\n"), width, height, title = "current",
            borderStyle = Style().faint(), titleStyle = Style().fg(Accent))

proc logPane(m: Model, width, height: int): string =
  let inner = width - 4
  var rows: seq[string]
  let visible = max(height - 2, 1)
  let start = max(m.logs.len - visible, 0)
  for i in start ..< m.logs.len:
    let e = m.logs[i]
    let stamp = Style().faint().render(&"{e.elapsed.inMilliseconds/1000:6.1f}s ")
    let level = e.level.levelStyle.render(padVisible(e.level, 6))
    rows.add "  " & truncateVisible(stamp & level & e.text, inner)
  renderBox(rows.join("\n"), width, height, title = "events",
            borderStyle = Style().faint(), titleStyle = Style().fg(Accent))

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let uptime = (getMonoTime() - m.started).inMilliseconds.float / 1000.0
  let state = if m.paused: Style().fg(WarnColour).render("paused")
              else: Style().fg(Accent).render(spinner(m.frame) & " live")
  let header = Style().bold().render("  nimtui dashboard  ") & state &
    Style().faint().render(&"   {m.samples} samples · up {uptime:.1f}s · " &
                           &"{m.size.width}x{m.size.height}")
  let footer = " " & hints({"space": "pause", "r": "reset", "q": "quit"})
  let bodyHeight = max(m.size.height - 3, 6)

  let body =
    if m.size.width < 76:
      # Narrow: single column, only the first series keeps its chart.
      let top = max(bodyHeight - 8, 5)
      joinVertical(m.series[0].seriesPane(m.size.width, top),
                   m.gaugePane(m.size.width, bodyHeight - top))
    else:
      # `splitWidths` rather than `width div 2` and a remainder by hand. Equal
      # halves are the easy case; the bottom row is 2:3, which is where doing it
      # by hand goes wrong — round each share on its own and the row comes out a
      # column over, which wraps and drags the whole frame out of step.
      let top = splitWidths(m.size.width, 2)
      let bottom = splitWidths(m.size.width, [2.0, 3.0])
      let topHeight = max(bodyHeight * 3 div 5, 6)
      joinVertical(
        joinHorizontal([m.series[0].seriesPane(top[0], topHeight),
                        m.series[1].seriesPane(top[1], topHeight)]),
        joinHorizontal([m.gaugePane(bottom[0], bodyHeight - topHeight),
                        m.logPane(bottom[1], bodyHeight - topHeight)]))

  joinVertical(header, body, footer)

when isMainModule:
  var model = Model(started: getMonoTime())
  model.series = @[
    Series(label: "requests/s", unit: "/s", colour: rgb(120, 220, 200)),
    Series(label: "latency", unit: "ms", colour: rgb(200, 160, 255)),
    Series(label: "cpu", unit: "%", colour: rgb(250, 190, 100)),
    Series(label: "memory", unit: "%", colour: rgb(140, 200, 255)),
  ]
  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor},
                     initCmd = batch(spin(), sample(), logTick())).run()
