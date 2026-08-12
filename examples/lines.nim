## The same series as bars and as a trace, and what each of the three plotting
## glyphs can say.
##
## `sparkline` and `barChart` fill every column from the bottom of the chart up to
## its value, so a cell answers *how big*. `lineSpark` and `lineChart` draw where
## the value went instead, which needs a glyph that divides the cell in both
## directions — and there are three worth having:
##
## * **braille**, `U+2800`..`U+28FF`, 2x4 dots per cell. Eight sub-cells, so a
##   one-row chart still resolves four heights and holds two values per column.
##   The default, and the only one that says much in a single row.
## * **quadrant blocks**, 2x2. Half the detail, in every font that can already
##   draw a box border — which braille cannot be relied on for.
## * **ascii**, one `*` per cell. Nothing to be missing, and the honest fallback:
##   it loses resolution rather than correctness.
##
## The table gives one row per series and one column per way of drawing it at the
## same width, which is the comparison: bars read a single sample well and a shape
## badly, and the trace the other way round. Ascii is not among them, because at
## one row it has a single height and so draws every series as a solid line — the
## `g` key puts it in the panel below, where there are rows for it to use.
##
## The two panels are the selected series at full height, drawn both ways from the
## same numbers, and their footers say what each way cost: a cell is a cell, so
## the trace columns hold twice the history of the bar column beside them.
##
## Two things here that are properties of the widget rather than of this example:
##
## * **A trace needs no flat-series special case.** `barChart` lifts a constant
##   series to the shortest visible bar, because a bar of zero height is blank and
##   would look like no data; a line at zero is a line along the bottom row.
## * **`dotsX`/`dotsY` are exported because the caller sizes the history.** A
##   chart `w` cells wide holds `w * dotsX` values, so how much to keep is the
##   glyph set's question, not a guess — the panel footers spell out both.
##
##   nim c -r --path:src examples/lines.nim

import std/[random, math, strutils, strformat]
import nimtui

const
  SampleInterval = initDuration(milliseconds = 200)
  History = 320                ## ≥ 2 per column at any sane terminal width
  Prefill = 140
  T = DefaultTheme

type
  SampleMsg = ref object of Msg

  Shape = enum
    ## Four shapes whose *traces* differ; unlike `examples/sparklines.nim` this
    ## one is not about distributions, so they only have to disagree over time.
    shSine = "sine", shWalk = "walk", shSaw = "sawtooth", shSpikes = "spikes"

  Series = object
    shape: Shape
    values: seq[float]

  Model = object
    series: seq[Series]
    n: int                     ## samples taken; also the generators' phase
    sel: int
    glyphs: PlotGlyphs
    rows: int                  ## chart height in the panels
    fixedScale: bool
    colour: bool
    paused: bool
    size: TermSize

# --- fake data ----------------------------------------------------------------

var rng = initRand(0x1ead)

proc nextValue(s: Shape, n: int, last: float): float =
  ## All four on 0-100, so a fixed scale has something to be fixed to.
  case s
  of shSine: 50.0 + 45.0 * sin(n.float * PI / 21.0)
  of shWalk: clamp(last + rng.rand(-9.0 .. 9.0) + (50.0 - last) * 0.06, 0.0, 100.0)
  of shSaw: 2.0 + (n mod 28).float / 27.0 * 96.0
  of shSpikes: (if n mod 19 == 0: rng.rand(70.0 .. 100.0) else: rng.rand(4.0 .. 16.0))

proc sample(m: var Model) =
  for i in 0 .. m.series.high:
    let last = if m.series[i].values.len == 0: 50.0 else: m.series[i].values[^1]
    m.series[i].values.add nextValue(m.series[i].shape, m.n, last)
    if m.series[i].values.len > History:
      m.series[i].values.delete(0)
  inc m.n

proc tickCmd(): Cmd = after(SampleInterval, SampleMsg())

# --- update -------------------------------------------------------------------

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)

  if msg of SampleMsg:
    if not m.paused: result[0].sample()
    result[1] = tickCmd()

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("up", "k"): result[0].sel = max(m.sel - 1, 0)
    elif k.matches("down", "j"): result[0].sel = min(m.sel + 1, m.series.high)
    elif k.matches("g"):
      # Wraps, so the key needs no counterpart and the enum can grow.
      result[0].glyphs = PlotGlyphs((m.glyphs.ord + 1) mod (PlotGlyphs.high.ord + 1))
    elif k.matches("+", "="): result[0].rows = min(m.rows + 1, 16)
    elif k.matches("-"): result[0].rows = max(m.rows - 1, 1)
    elif k.matches("s"): result[0].fixedScale = not m.fixedScale
    elif k.matches("c"): result[0].colour = not m.colour
    elif k.matches("space", "p"): result[0].paused = not m.paused
    elif k.matches("r"):
      # Empties the history rather than refilling it: both widgets pad on the
      # left when there are fewer values than columns, so this is how to see a
      # trace grow rightwards instead of being drawn as a full window.
      for i in 0 .. result[0].series.high: result[0].series[i].values.setLen 0
      result[0].n = 0

# --- drawing ------------------------------------------------------------------
#
# One place decides the scale for every chart on screen, since the whole example
# is a comparison and a panel quietly auto-scaling while the one beside it is
# fixed would make the two disagree for a reason that is not the glyphs.

proc scale(m: Model): (float, float) =
  if m.fixedScale: (0.0, 100.0) else: (0.0, 0.0)

proc trace(m: Model, values: openArray[float], w, h: int,
           glyphs: PlotGlyphs): seq[string] =
  let (lo, hi) = m.scale
  if m.colour: lineChart(values, w, h, T.ramp, lo, hi, glyphs)
  else: lineChart(values, w, h, lo, hi, glyphs)

proc bars(m: Model, values: openArray[float], w, h: int): seq[string] =
  let (lo, hi) = m.scale
  if m.colour: barChart(values, w, h, T.ramp, lo, hi)
  else: barChart(values, w, h, lo, hi)

# --- view ---------------------------------------------------------------------

const NameW = 8                ## exactly `sawtooth`, the longest shape name

type Plan = tuple[sets: seq[PlotGlyphs], chart: seq[int]]
  ## Which glyph sets get a column, and how wide each chart column is.

proc plan(width: int): Plan =
  ## The chart columns take whatever the name column leaves, and the *fixed*
  ## widths are decided before anything is rendered: a chart cell is exactly as
  ## wide as the chart in it, so a column shrunk after the fact elides its cells
  ## to `…`, which is not a smaller chart but no chart at all.
  ##
  ## Bars and braille are the comparison the example exists to make, so they are
  ## the two that survive a narrow terminal. Braille is also the one whose column
  ## can least afford to be cut in half — it carries two values per cell.
  let sets = if width >= 72: @[pgBraille, pgBlocks]
             else: @[pgBraille]
  let
    cols = sets.len + 2                          # the name and the bars column
    chrome = (cols + 1) + cols * 2               # the same arithmetic `Table` does
    room = max(width - chrome - NameW, 8 * (sets.len + 1))
  (sets, splitWidths(room, sets.len + 1))

proc label(g: PlotGlyphs): string =
  case g
  of pgBraille: "braille"
  of pgBlocks: "blocks"
  of pgAscii: "ascii"

proc header(name: string, samples, width: int): string =
  ## The column's name, and how many samples are in one of its cells when there is
  ## room to say so — which is the one thing about these two columns that a reader
  ## cannot get from looking at them. A header too wide for its fixed column is
  ## elided like any other cell, so it has to fit rather than be trusted to.
  let full = &"{name} ({samples})"
  if displayWidth(full) <= width: full else: name

proc dataTable(m: Model, p: Plan): (string, int) =
  ## One row per series, one column per way of drawing it. The table, and the
  ## number of lines it came to.
  var columns = @[column("series", width = NameW, style = T.accentStyle),
                  column(header("bars", p.chart[0], p.chart[0]),
                         width = p.chart[0])]
  for i, g in p.sets:
    let w = p.chart[i + 1]
    columns.add column(header(label(g), w * dotsX(g), w), width = w)

  var t = table(columns, SquareBorder)
  t.borderStyle = T.borderStyle
  for i in 0 .. t.columns.high: t.columns[i].headerStyle = T.titleStyle
  t.zebra = Style().bg(T.border.darken(0.45))

  let (lo, hi) = m.scale
  for s in m.series:
    var cells = @[$s.shape]
    # `sparkline` has no `lo`/`hi`, so a fixed scale is a one-row `barChart` —
    # the same glyphs with the scale in the caller's hands.
    cells.add(if m.fixedScale: m.bars(s.values, p.chart[0], 1)[0]
              elif m.colour: sparkline(s.values, p.chart[0], T.ramp)
              else: sparkline(s.values, p.chart[0]))
    for i, g in p.sets:
      cells.add(if m.colour: lineSpark(s.values, p.chart[i + 1], T.ramp, lo, hi, g)
                else: lineSpark(s.values, p.chart[i + 1], lo, hi, g))
    t.rows.add cells

  t.rowStyles = newSeq[Style](t.rows.len)
  t.rowStyles[m.sel] = Style().bg(T.border.darken(0.15)).bold()
  # Natural width, not `render(width)`: the widths above already sum to it, and
  # passing a total invites the shrink pass onto the widest column — a chart.
  (t.render(), t.rows.len + 4)

proc panels(m: Model, width, height: int): string =
  ## The selected series at full height, as a trace and as bars.
  ##
  ## Same numbers, same scale, side by side, because the difference between them
  ## is the example: the bars are a silhouette and the trace is a path, and at
  ## this height that is no longer a matter of taste — a spike and a step look
  ## alike as columns and nothing alike as a line.
  let
    s = m.series[m.sel]
    rows = min(m.rows, max(height - 2, 1))
  var widths = if width >= 60: splitWidths(width, 2, gap = 1) else: @[width]
  var blocks: seq[string]

  for i, w in widths:
    let inner = max(w - 2, 1)
    var body: string
    var title, footer: string
    if i == 0:
      body = m.trace(s.values, inner, rows, m.glyphs).join("\n")
      title = "lineChart · " & label(m.glyphs)
      # What the glyph set buys, in the two numbers the caller actually needs:
      # how many values fit and how many heights they land on.
      footer = &"{inner * dotsX(m.glyphs)} values · " &
               &"{rows * dotsY(m.glyphs)} heights"
    else:
      body = m.bars(s.values, inner, rows).join("\n")
      title = "barChart"
      footer = &"{inner} values · {rows * 8} heights"
    blocks.add renderBox(body, w, rows + 2, title = title, footer = footer,
                         border = SquareBorder, borderStyle = T.borderStyle,
                         titleStyle = T.titleStyle, footerStyle = T.mutedStyle)
  joinHorizontal(blocks, gap = 1)

proc hintLine(width: int): string =
  ## The longest set of hints that fits, measured rather than guessed at from a
  ## width. `hints` is as long as its labels, so a threshold picked by eye is
  ## wrong as soon as one of them changes — and a footer a few columns over is
  ## clipped mid-word by the renderer, which reads as a missing key rather than
  ## as a narrow terminal.
  const sets = [
    @[("↑↓", "series"), ("g", "glyphs"), ("+-", "height"), ("s", "scale"),
      ("c", "colour"), ("space", "pause"), ("r", "reset"), ("q", "quit")],
    @[("↑↓", "series"), ("g", "glyphs"), ("+-", "height"), ("s", "scale"),
      ("q", "quit")],
    @[("↑↓", "series"), ("g", "glyphs"), ("q", "quit")]]
  for s in sets:
    result = hints(s)
    if displayWidth(result) <= width: return

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let
    p = plan(m.size.width)
    (tbl, tableHeight) = m.dataTable(p)
    scaleName = if m.fixedScale: "fixed 0-100" else: "own window"
  # The caption a chart cannot carry: which values are on screen, and what they
  # were scaled against. Every chart in the frame is on the same footing, which
  # is the only way the columns can be compared at all.
  var lines = @[
    (span(" lines", T.titleStyle) &
     span(&"   {m.n} samples · {scaleName}" &
          (if m.paused: " · paused" else: ""), T.mutedStyle)).render(),
    "",
    tbl]

  # Five: the header, the two blank separators, the hints, and the blank above
  # the panels. One short and the hints line falls off the bottom of the frame,
  # which the renderer clips silently — the footer simply is not there.
  let rest = m.size.height - tableHeight - 5
  if rest >= 5:
    lines.add ""
    lines.add m.panels(m.size.width, rest)

  lines.add ""
  lines.add hintLine(m.size.width)
  lines.join("\n")

when isMainModule:
  var model = Model(glyphs: pgBraille, rows: 6, colour: true)
  for shape in Shape:
    model.series.add Series(shape: shape)
  # Prefilled so there is a shape to read on the first frame; `r` empties it.
  for _ in 0 ..< Prefill: model.sample()

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor},
                     initCmd = tickCmd()).run()
