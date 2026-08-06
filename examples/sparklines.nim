## Sparklines as table cells: patterns down one column, distributions down another.
##
## What this example is really about: a sparkline is one *cell*, so a table of
## them is a table of shapes. Eight synthetic series, each named for the shape it
## traces, are drawn twice — once as a trend over time, and once as a histogram
## of where their values actually fell. The two columns disagree on purpose:
## `sawtooth` and `heavy tail` trace nothing alike and `spikes` and `heavy tail`
## have almost the same distribution while looking nothing alike over time. One
## column is the shape of the signal, the other the shape of the data.
##
## Also shows the two things about the widget that are easy to get wrong:
##
## * **Each sparkline scales to its own window** — min to max of the trailing
##   `width` values — so one row's *shape* is comparable with another's and its
##   *heights are not*: `flatline` and `sine` both fill their cell, top to
##   bottom. The `window` column exists to make that visible, and `s` switches
##   the trend column to a fixed 0-100 scale to show the other reading.
## * **A fixed scale is a `barChart` one row tall**, since `sparkline` has no
##   `lo`/`hi` and should not grow a pair — that is the same eighth-block glyphs
##   with the scale in the caller's hands. The distribution column always uses
##   it, for the reason given on `distribution` below.
##
## Both of those are why the numbers are here at all. A sparkline says *what
## shape*, never *how big*, and a column of them beside no numbers at all is the
## commonest way to draw one that misleads.
##
##   nim c -r --path:src examples/sparklines.nim

import std/[random, math, algorithm, strutils, strformat]
import nimtui

const
  SampleInterval = initDuration(milliseconds = 200)
  History = 240
  Prefill = 90
  T = DefaultTheme

type
  SampleMsg = ref object of Msg

  Shape = enum
    ## Named for what to look for in the trend column. Chosen so that no two
    ## share both a trace and a distribution: the pairs that agree on one of
    ## those disagree on the other, which is the whole argument for drawing both.
    shSteady = "steady", shWalk = "walk", shSaw = "sawtooth", shSine = "sine",
    shSpikes = "spikes", shBimodal = "bimodal", shHeavy = "heavy tail",
    shFlat = "flatline"

  Series = object
    shape: Shape
    values: seq[float]

  Model = object
    series: seq[Series]
    n: int                   ## samples taken; also the phase the generators run on
    sel: int
    fixedScale: bool
    colour: bool
    paused: bool
    size: TermSize

# --- fake data ----------------------------------------------------------------

var rng = initRand(0xf00d)

proc nextValue(s: Shape, n: int, last: float): float =
  ## One sample of each shape, all on the same 0-100 scale so a fixed scale has
  ## something to be fixed to.
  case s
  of shSteady:
    clamp(50.0 + rng.gauss(0.0, 2.5), 0.0, 100.0)
  of shWalk:
    clamp(last + (50.0 - last) * 0.04 + rng.gauss(0.0, 6.0), 0.0, 100.0)
  of shSaw:
    2.0 + (n mod 24).float / 23.0 * 96.0
  of shSine:
    50.0 + 45.0 * sin(n.float * PI / 15.0)
  of shSpikes:
    if n mod 17 == 0: clamp(90.0 + rng.gauss(0.0, 4.0), 0.0, 100.0)
    else: clamp(12.0 + rng.gauss(0.0, 3.0), 0.0, 100.0)
  of shBimodal:
    if (n div 9) mod 2 == 0: clamp(22.0 + rng.gauss(0.0, 2.0), 0.0, 100.0)
    else: clamp(78.0 + rng.gauss(0.0, 2.0), 0.0, 100.0)
  of shHeavy:
    pow(rng.rand(1.0), 3.0) * 100.0
  of shFlat:
    42.0

proc sample(m: var Model) =
  for i in 0 .. m.series.high:
    let last = if m.series[i].values.len == 0: 50.0 else: m.series[i].values[^1]
    m.series[i].values.add nextValue(m.series[i].shape, m.n, last)
    if m.series[i].values.len > History: m.series[i].values.delete 0
  m.n.inc

# --- reading a series ---------------------------------------------------------

proc windowRange(values: openArray[float], w: int): (float, float) =
  ## The min and max of the trailing `w` values — the range `sparkline` scaled
  ## its glyphs against, and the one thing the glyphs cannot say about
  ## themselves. Without it `flatline` and `sine` are the same picture.
  if values.len == 0 or w <= 0: return (0.0, 0.0)
  let start = max(values.len - w, 0)
  result = (values[start], values[start])
  for i in start ..< values.len:
    result[0] = min(result[0], values[i])
    result[1] = max(result[1], values[i])

proc histogram(values: openArray[float], buckets: int): seq[float] =
  ## How many samples fall in each of `buckets` equal slices of the series'
  ## range. One bucket per column, so the sparkline drawn from this has an x
  ## axis of value rather than of time.
  if buckets <= 0 or values.len == 0: return @[]
  var (lo, hi) = (values[0], values[0])
  for v in values:
    lo = min(lo, v)
    hi = max(hi, v)
  let span = max(hi - lo, 1e-9)
  result = newSeq[float](buckets)
  for v in values:
    # `min` rather than a bucket per boundary: the top of the range would
    # otherwise land in a bucket of its own, one sample wide.
    result[min(int((v - lo) / span * buckets.float), buckets - 1)] += 1.0

proc quantile(values: openArray[float], q: float): float =
  if values.len == 0: return 0.0
  var sorted = @values
  sorted.sort()
  sorted[clamp(int(q * sorted.high.float + 0.5), 0, sorted.high)]

# --- the two cells ------------------------------------------------------------

proc trend(m: Model, values: openArray[float], w: int): string =
  ## The series over time, in whichever of the two scales is switched on.
  ##
  ## `sparkline` scales to its window and has no way not to. A *fixed* scale is
  ## `barChart` one row tall: the same glyph set, plus the `lo`/`hi` that a row
  ## has to have before its height can be compared with the row above it. Worth
  ## flipping between with `s` — under a fixed scale `steady` and `flatline`
  ## become nearly the same picture, which under the per-row scale they are not,
  ## and `spikes` stops looking like a signal that swings from nothing to
  ## everything.
  ##
  ## Both overloads take the `Gradient` as a required argument rather than a
  ## default, hence the pair of calls in each arm.
  ##
  ## One difference beyond the scale, visible on `sawtooth` where it resets: a
  ## value sitting at `lo` is a *blank* cell under `barChart` and `▁` under
  ## `sparkline`, which have no lower glyph. Blank is right for a fixed scale —
  ## the value really is at the bottom — and would be wrong for a window scale,
  ## where the lowest value is only the lowest one that happened.
  if m.fixedScale:
    let rows = if m.colour: barChart(values, w, 1, T.ramp, lo = 0.0, hi = 100.0)
               else: barChart(values, w, 1, lo = 0.0, hi = 100.0)
    if rows.len > 0: rows[0] else: ""
  elif m.colour: sparkline(values, w, T.ramp)
  else: sparkline(values, w)

proc distribution(m: Model, values: openArray[float], w: int): string =
  ## The same history as a histogram: how often each level occurred, where the
  ## trend says when.
  ##
  ## A one-row `barChart` and not `sparkline`, with `lo` pinned to 0 and `hi` the
  ## busiest bucket. An auto-scaled histogram puts the *emptiest* bucket at the
  ## bottom of the scale, which is wrong in both directions at once: a bucket
  ## holding nothing draws the same `▁` as one holding a tenth of the samples,
  ## and a distribution with something in every bucket draws its thinnest tail as
  ## though it were empty. `sparkline` cannot express the difference — its lowest
  ## value is `▁`, never a blank cell — and this is the case that shows why the
  ## fixed-scale form is worth having.
  let counts = histogram(values, w)
  if counts.len == 0: return ""
  var hi = 0.0
  for c in counts: hi = max(hi, c)
  let rows = if m.colour: barChart(counts, w, 1, T.ramp, lo = 0.0, hi = hi)
             else: barChart(counts, w, 1, lo = 0.0, hi = hi)
  if rows.len > 0: rows[0] else: ""

# --- update -------------------------------------------------------------------

proc tickCmd(): Cmd = after(SampleInterval, SampleMsg())

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)

  if msg of SampleMsg:
    if not m.paused: result[0].sample()
    result[1] = tickCmd()

  elif msg of KeyMsg:
    case $KeyMsg(msg)
    of "q", "ctrl+c": result[1] = quitCmd()
    of "up", "k": result[0].sel = max(m.sel - 1, 0)
    of "down", "j": result[0].sel = min(m.sel + 1, m.series.high)
    of "s": result[0].fixedScale = not m.fixedScale
    of "c": result[0].colour = not m.colour
    of "space", "p": result[0].paused = not m.paused
    of "r":
      # Empties the history rather than refilling it, so the lines grow
      # rightwards out of the left padding — `sparkline` pads on the left when
      # there are fewer values than columns, which is what stops a young series
      # from being drawn as though it were a full window.
      for i in 0 .. result[0].series.high: result[0].series[i].values.setLen 0
      result[0].n = 0
    else: discard

# --- view ---------------------------------------------------------------------

type Plan = tuple[cols: int, spark: seq[int]]
  ## How many columns fit, and how wide the two sparkline columns are. Decided
  ## once and passed to both the table and the header line, since the header
  ## names the trend column's window and would otherwise derive it a second time.

proc plan(width: int): Plan =
  ## The text columns are fixed and the two sparkline columns take what is left
  ## over. That way round because a sparkline cell is exactly as wide as the
  ## sparkline in it: a column shrunk by one column after the fact elides its
  ## cells to `…`, which is not a smaller chart but no chart at all.
  ##
  ## Three tiers, dropping the numbers before the charts. The charts are what the
  ## example is; the two sparkline columns are the last thing to go, and a table
  ## wider than the terminal is not an option at all — the renderer assumes no
  ## line wrapping, so it would truncate every row of the frame.
  let cols = if width >= 96: 6 elif width >= 66: 4 else: 3
  # 10 columns is exactly `heavy tail`, the longest name, so the narrow tier
  # loses no text by taking the two columns of margin back for the charts.
  var textWidth = if cols == 3: 10 else: 12    # pattern
  if cols >= 4: textWidth += 7                 # now
  if cols == 6: textWidth += 11 + 6            # window, p95
  # The same arithmetic `Table` does: the frame, plus a pad either side of every
  # cell. Getting it wrong here costs a column of sparkline, not a broken frame,
  # since the table is rendered at its natural width below.
  let chrome = (cols + 1) + cols * 2
  (cols, splitWidths(max(width - chrome - textWidth, 12), [0.58, 0.42]))

proc dataTable(m: Model, p: Plan): (string, int) =
  ## The table, and the number of lines it came to.
  let spark = p.spark

  var columns = @[
    column("pattern", width = if p.cols == 3: 10 else: 12, style = T.accentStyle),
    column("trend", width = spark[0])]
  if p.cols >= 4:
    columns.add column("now", width = 7, align = aRight, headerAlign = aRight)
  if p.cols == 6:
    columns.add column("window", width = 11, align = aRight,
                       headerAlign = aRight, style = T.mutedStyle)
  # A header wider than its fixed column is elided like any other cell, so the
  # narrow one gets a name that fits rather than `distributi…`.
  columns.add column(if spark[1] >= 12: "distribution" else: "levels",
                     width = spark[1])
  if p.cols == 6:
    columns.add column("p95", width = 6, align = aRight, headerAlign = aRight,
                       style = T.mutedStyle)

  var t = table(columns, SquareBorder)
  t.borderStyle = T.borderStyle
  for i in 0 .. t.columns.high: t.columns[i].headerStyle = T.titleStyle
  # A zebra stripe under a coloured sparkline works because `Spans.render`
  # re-arms the row's style after any reset in the cell's own escapes — without
  # that the stripe would stop at the first glyph and leave the rest of the row
  # bare.
  t.zebra = Style().bg(T.border.darken(0.45))

  for s in m.series:
    let
      cur = if s.values.len == 0: 0.0 else: s.values[^1]
      (lo, hi) = windowRange(s.values, spark[0])
    var cells = @[$s.shape, m.trend(s.values, spark[0])]
    if p.cols >= 4: cells.add &"{cur:5.1f}"
    # One decimal, not rounded to whole numbers: a `now` of 50.8 beside a window
    # of `51–53` reads as a contradiction rather than as rounding.
    if p.cols == 6: cells.add &"{lo:.1f}–{hi:.1f}"
    cells.add m.distribution(s.values, spark[1])
    if p.cols == 6: cells.add &"{quantile(s.values, 0.95):5.1f}"
    t.rows.add cells

  t.rowStyles = newSeq[Style](t.rows.len)
  t.rowStyles[m.sel] = Style().bg(T.border.darken(0.15)).bold()

  # `render()` at its natural width rather than `render(width)`: the widths above
  # already sum to it, and passing a total invites the shrink pass — which picks
  # the widest column, and the widest column is the sparkline.
  (t.render(), t.rows.len + 4)

proc detail(m: Model, width, height: int): string =
  ## The selected series on its own, at three window widths and as a histogram
  ## with its range spelled out.
  ##
  ## Same data in all three lines, three different pictures — which is the point:
  ## `sparkline` draws the trailing `width` values and rescales to them, so a
  ## wider cell is more history rather than more detail, and a narrow one shows
  ## swings that the wide one flattens into the baseline.
  let
    s = m.series[m.sel]
    inner = width - 2
    labelW = 10
    rangeW = 13
    full = max(inner - labelW - rangeW, 12)
  var rows: seq[string]

  for w in [12, 32, full]:
    let (lo, hi) = windowRange(s.values, w)
    var line = span(padVisible("last " & $w, labelW), T.mutedStyle)
    # The range before the sparkline, so the three lines start in the same
    # column however long each sparkline is.
    line.add(padVisible(&"{lo:.1f}–{hi:.1f}", rangeW), T.mutedStyle)
    line.add m.trend(s.values, w)
    rows.add line.render()

  rows.add ""
  let (lo, hi) = windowRange(s.values, History)
  var histLine = span(padVisible("histogram", labelW), T.mutedStyle)
  histLine.add(spaces(rangeW))
  histLine.add m.distribution(s.values, full)
  rows.add histLine.render()
  # An axis under the buckets: the histogram's x axis is value, not time, and its
  # two ends are the only labels there is room for.
  let
    loLabel = &"{lo:.1f}"
    hiLabel = &"{hi:.1f}"
  rows.add span(spaces(labelW + rangeW) &
                padVisible(loLabel, max(full - hiLabel.len, 1)) & hiLabel,
                T.mutedStyle).render()
  rows.add ""
  rows.add span(&"{s.values.len} samples · the three lines are the same data, " &
                "each rescaled to its own window", T.mutedStyle).render()

  # Sized to its content rather than to the space available: a panel stretched to
  # fill the terminal is eight rows of chart and a dozen of nothing.
  renderBox(rows.join("\n"), width, min(height, rows.len + 2), title = $s.shape,
            border = SquareBorder, borderStyle = T.borderStyle,
            titleStyle = T.titleStyle)

proc hintLine(width: int): string =
  ## The longest set of hints that fits, measured rather than guessed at from a
  ## width. `hints` is as long as its labels, so a threshold picked by eye is
  ## wrong as soon as one of them changes — and a footer a few columns over is
  ## clipped mid-word by the renderer, which reads as a missing key rather than
  ## as a narrow terminal.
  const sets = [
    @[("↑↓", "select"), ("s", "scale"), ("c", "colour"), ("space", "pause"),
      ("r", "reset"), ("q", "quit")],
    @[("↑↓", "select"), ("s", "scale"), ("c", "colour"), ("q", "quit")],
    @[("↑↓", "select"), ("s", "scale"), ("q", "quit")]]
  for s in sets:
    result = hints(s)
    if displayWidth(result) <= width: return

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let
    p = plan(m.size.width)
    scale = if m.fixedScale: "fixed 0-100" else: "own window"
    (tbl, tableHeight) = m.dataTable(p)
  # What each column is *of*, which is the caption a sparkline cannot carry and
  # the reason the two columns can disagree without either being wrong: the trend
  # is the last `spark[0]` samples, the histogram is every sample kept.
  # The narrow tier drops the title rather than the numbers: which window each
  # column is of is the caption, and the table below is not going to be mistaken
  # for anything else.
  let head =
    if p.cols == 3: span(&" last {p.spark[0]}, {scale} · all {m.n}", T.mutedStyle)
    else: span(" sparklines", T.titleStyle) &
          span(&"   trend: last {p.spark[0]}, {scale} · " &
               &"distribution: all {m.n}", T.mutedStyle)
  var lines = @[
    (head & span(if m.paused: " · paused" else: "", T.mutedStyle)).render(),
    "",
    tbl]

  # The detail panel is what gives way on a short terminal: the table is the
  # example, and half a panel says less than none.
  #
  # Five: the header, the two blank separators, the hints, and the blank above the
  # panel. One short and the hints line falls off the bottom of the frame, which
  # the renderer clips silently — the footer simply is not there.
  let rest = m.size.height - tableHeight - 5
  if rest >= 7:
    lines.add ""
    lines.add m.detail(m.size.width, rest)

  lines.add ""
  lines.add hintLine(m.size.width)
  lines.join("\n")

when isMainModule:
  var model = Model(colour: true)
  for shape in Shape:
    model.series.add Series(shape: shape)
  # Prefilled so the shapes are there to read on the first frame; `r` empties it
  # again, which is the way to see a series grow out of the left padding.
  for _ in 0 ..< Prefill: model.sample()

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor},
                     initCmd = tickCmd()).run()
