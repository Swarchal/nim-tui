## Small indicators that render to a string: bars, charts, spinners, key hints.
##
## Each returns a plain string of exactly the width asked for, so the results drop
## into a `view` directly or into a `nimtui/layout <layout.html>`_ block.
##
## ```nim
## echo gauge(0.62, 20)                     # ██████████████▏░░░░░
## echo sparkline(@[3.0, 9.0, 4.0], 20)
## echo spinner(frame) & " working"
## echo hints({"space": "pause", "q": "quit"})
## ```
##
## Sub-cell resolution comes from the partial block glyphs: `gauge` resolves an
## eighth of a cell so a short bar still moves, and `barChart` an eighth of a row.
##
## `sparkline` and `barChart` are bars — every column is filled from the bottom of
## the chart up to its value. `lineSpark` and `lineChart` are the same data drawn
## as a *trace*, using a glyph that divides the cell in both directions, so what
## is on screen is where the value went rather than how big it was:
##
## ```nim
## echo sparkline(cpu, 20)                  # ▁▂▅█▇▄▂▂▂▅▇▆▃▂▁▁▃▅▇█
## echo lineSpark(cpu, 10)                  # ⣀⡞⠹⢤⡴⠛⢦⣀⡴⠚   the same 20 values
## echo lineChart(cpu, 10, 3).join("\n")    # three rows, twelve heights
## ```
##
## `gauge`, `sparkline`, `barChart`, `lineSpark` and `lineChart` each take an
## optional `Gradient <color.html#Gradient>`_ as an extra argument, which colours
## the result by position or by value:
##
## ```nim
## echo gauge(0.72, 30, HeatGradient)       # green at the left, red at the right
## echo sparkline(cpu, 40, CoolGradient)    # each glyph coloured by its height
## ```
##
## A gradient `gauge` fills with `▌` and puts the next point on the ramp behind
## it, so every cell carries two colours and the bar is twice as smooth as its
## width — sub-cell resolution again, in colour rather than in shape.
##
## That argument is required rather than defaulted, so the uncoloured calls above
## stay unambiguous — a `Gradient` with a default value would make `gauge(0.5, 20)`
## match both overloads.
##
## A coloured `sparkline` or `barChart` paints a *completely* filled cell as a
## space with the colour in the **background** instead of drawing `█` in the
## foreground. A background fill covers the whole cell by definition, where a
## glyph covers as much of it as the font says: plenty of fonts draw `█` a hair
## short of the cell box, which shows as a thin seam of the terminal's own
## background between one filled cell and the next — a bar striped into blocks
## rather than a bar. `solid = false` on either restores the glyph.

import std/[strutils, math]
import ./[ansi, style, spans]
export style, spans

const
  SpinnerFrames* = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    ## Braille dots, ten frames. Every frame is one column wide.
  SparkChars* = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    ## Eighth-height blocks, ascending, for sparklines and column charts.
  PartialBlocks* = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
    ## Eighth-width blocks, ascending, indexed by eighths so 0 is empty.

proc gauge*(fraction: float, width: int, full = "█", empty = "░"): string =
  ## A horizontal bar `width` columns wide. `fraction` is clamped to 0..1.
  ##
  ## Uses partial block glyphs, so a bar that is a fraction of a cell long still
  ## shows movement rather than snapping between whole cells.
  if width <= 0: return ""
  let f = clamp(fraction, 0.0, 1.0)
  let exact = f * width.float
  let whole = exact.int
  let rest = exact - whole.float
  result = full.repeat(min(whole, width))
  if whole < width:
    let eighth = (rest * 8).int
    if eighth > 0:
      result.add PartialBlocks[eighth]
      result.add empty.repeat(width - whole - 1)
    else:
      result.add empty.repeat(width - whole)

proc gauge*(fraction: float, width: int, fill: Gradient, empty = "░",
            emptyStyle = Style().faint(), full = "█", halfBlock = true): string =
  ## `gauge` with the filled cells coloured along `fill`.
  ##
  ## The ramp is laid over the *whole* bar, not over the filled part, so a given
  ## column is always the same colour whatever the current value. Ramping over
  ## the filled part instead would recolour every cell on each update, which
  ## reads as the bar flashing rather than growing — and would make 100% of a
  ## `HeatGradient` look identical to 10% of it.
  ##
  ## `halfBlock` draws the filled run as `▌` with the *next* point on the ramp as
  ## the cell's background, so each cell carries two samples and the bar is twice
  ## as smooth in the same columns — the sub-cell trick `lineChart` uses for
  ## shape, applied to colour. It is what `full` is for: with half-block on the
  ## glyph is `▌` by construction, so a caller wanting a different fill glyph
  ## passes `halfBlock = false` and gets one colour per cell.
  ##
  ## It turns itself off under `cpNoColor`, where `sgr` emits nothing and a row
  ## of bare `▌` would draw a bar half the width it means. Under `cpAnsi16` the
  ## two halves often round to the same colour, which costs nothing — that is a
  ## solid cell, exactly what the colours say.
  ##
  ## An `emptyStyle` carrying a **background** — a track colour — is also put
  ## behind the fractional cell at the bar's end, so the bar ends *on* the track.
  ## Without one that cell's remainder is the terminal's own background, and since
  ## every half-block cell is painted edge to edge, the bar then appears to stop
  ## short of a track it has not reached: a gap up to seven eighths of a cell
  ## wide.
  ##
  ## ```nim
  ## echo gauge(0.62, 30, HeatGradient,
  ##            emptyStyle = Style().faint().bg(hex"#2a2a35"))
  ## ```
  ##
  ## Pass `empty = " "` with it. A `░` track reads as its background *plus* the
  ## dots, which is lighter than the background alone — and the fractional cell
  ## can only be a glyph over the background, so a textured track meets the bar's
  ## end at a visibly darker step: the same gap in the same place, a shade rather
  ## than a hole. A solid track and that cell are the same colour and meet
  ## exactly. Keep `░` for the case with no track colour at all, since a
  ## background paints nothing under `cpNoColor` and a solid track would be
  ## invisible there — which is a choice the caller makes on
  ## `colorProfile <style.html#colorProfile>`_, as both examples do.
  ##
  ## Pick that colour *lighter* than the background it sits on. A track darker
  ## than the pane reads as a hole punched in it rather than as the part of the
  ## bar not yet reached, and the fractional cell — mostly track, by definition —
  ## is where it shows worst. `darken` is the trap: it subtracts lightness in HSL,
  ## so `border.darken(0.35)` on any of the built-in themes clips to `#000000`.
  if width <= 0: return ""
  let
    f = clamp(fraction, 0.0, 1.0)
    exact = f * width.float
    whole = min(exact.int, width)
    rest = exact - exact.int.float
    half = halfBlock and colorProfile() != cpNoColor
    colours = fill.ramp(if half: width * 2 else: width)
  var line: Spans
  for i in 0 ..< whole:
    line.add(if half: "▌" else: full,
             if half: Style().fg(colours[2 * i]).bg(colours[2 * i + 1])
             else: Style().fg(colours[i]))
  var used = whole
  if used < width:
    let eighth = (rest * 8).int
    if eighth > 0:
      # The bar's colour as a foreground only — a partial block already ends part
      # way across its cell, so a background of the *bar's* colour would paint
      # the empty remainder and over-report the value by up to seven eighths.
      #
      # The remainder is the **track's** background instead, when the track has
      # one. That is the same cell said twice: the glyph is the bar's end and the
      # background behind it is what the bar has not reached yet, which is
      # exactly what the `empty` cells after it are. Without it the cell's
      # remainder is the terminal's own background, and against a bar whose whole
      # cells are painted edge to edge — which every half-block cell is — that
      # reads as a gap between the end of the bar and the track rather than as
      # the bar ending. `emptyStyle` with no background leaves the bytes as they
      # were, so a gauge over the terminal's own background is unaffected.
      line.add(PartialBlocks[eighth],
               Style().fg(colours[if half: 2 * used else: used]).bg(emptyStyle.bgc))
      inc used
    if used < width:
      line.add(empty.repeat(width - used), emptyStyle)
  line.render()

const
  ThinBarFull* = "━"
    ## The run a `thinBar`_ is drawn from, and the weight its two halves match.
  ThinBarLeftHalf* = "╸"
    ## The left half of a cell inked: how a bar *ends* part way through one.
  ThinBarRightHalf* = "╺"
    ## The right half. Not used by `thinBar`_, which always starts at column
    ## zero, but exported for a bar that does not — a range, or a segment of a
    ## timeline — since the pair is only useful together.

proc thinBar*(fraction: float, width: int, empty = "─"): string =
  ## A bar drawn as a *rule* rather than as filled cells, resolving half a cell.
  ##
  ## The difference from `gauge`_ is where the sub-cell information lives. A
  ## gradient `gauge` puts it in the colour — two ramp samples behind one `▌` —
  ## so it has to turn itself off under `cpNoColor` and lose half its resolution
  ## with it. This puts it in the *glyph*: `━` is a full cell of rule and `╸` is
  ## the left half of one, so a bar of two and a half cells is drawn as such with
  ## no colour involved at all, and reads the same on a monochrome terminal.
  ##
  ## The cost of that is what it looks like: a rule through the middle of the
  ## row rather than a solid bar, which is a quieter thing and a different one.
  ## That is why it is a second widget rather than a flag on the first.
  ##
  ## `empty` is the light rule by default, so the unfilled part is still a track
  ## rather than a gap — a bar at zero is then visible, which `gauge`'s `░`
  ## achieves the other way round.
  if width <= 0: return ""
  let
    halves = clamp(int(round(clamp(fraction, 0.0, 1.0) * float(width * 2))),
                   0, width * 2)
    whole = halves div 2
  result = newStringOfCap(width * 3)
  for _ in 0 ..< whole: result.add ThinBarFull
  # A half is only reachable with `whole < width`, since `halves` is capped at
  # `width * 2` and an odd number below that leaves at least one cell.
  if halves mod 2 == 1:
    result.add ThinBarLeftHalf
    result.add empty.repeat(width - whole - 1)
  else:
    result.add empty.repeat(width - whole)

proc thinBar*(fraction: float, width: int, fill: Gradient, empty = "─",
              emptyStyle = Style().faint()): string =
  ## `thinBar`_ with the filled run coloured along `fill`.
  ##
  ## The ramp is laid over the whole bar rather than over the filled part, for
  ## the reason spelled out on `gauge`_. There is no half-block variant to choose
  ## here: the resolution is already in the glyph, so the colour is free to be
  ## one sample per cell and stay that way under every profile.
  if width <= 0: return ""
  let
    halves = clamp(int(round(clamp(fraction, 0.0, 1.0) * float(width * 2))),
                   0, width * 2)
    whole = halves div 2
    colours = fill.ramp(width)
  var line: Spans
  for i in 0 ..< whole:
    line.add(ThinBarFull, Style().fg(colours[i]))
  var used = whole
  if halves mod 2 == 1:
    line.add(ThinBarLeftHalf, Style().fg(colours[used]))
    inc used
  if used < width:
    line.add(empty.repeat(width - used), emptyStyle)
  line.render()

func isGap*(v: float): bool =
  ## Whether a value is *missing* rather than small — the rule every chart here
  ## reads, and the reason they take `float` rather than an option type: a series
  ## with holes in it already has a spelling for them.
  ##
  ## Any value that is not finite is a gap, so `NaN` and both infinities qualify.
  ## `NaN` is what a hole in a measured series arrives as; an infinity is not a
  ## hole but it is not plottable either, and left in the data it would take the
  ## auto-scale with it and flatten every real value against the axis.
  ##
  ## A gap is drawn as nothing, never as zero, in all four of `sparkline`,
  ## `barChart`, `lineSpark` and `lineChart`, and it is excluded from the scale.
  ## For the bars that means the `absent` glyph, since a blank column already
  ## means a value at the bottom of the scale; for the traces it means the line
  ## *breaks* rather than being drawn through the hole.
  not (abs(v) < Inf)

func oneColumn(s: string): string =
  ## `s` cut or padded to exactly one column, for a glyph a caller supplied.
  ##
  ## A widget's width is its contract, and a two-column rune arriving in a chart
  ## is the frame-desynchronising failure rather than a chart that looks wrong.
  ## The already-correct case is returned untouched, per the layout rule: this
  ## runs once per call, but so does the reasoning that makes it free.
  if displayWidth(s) == 1: s else: padVisible(truncateVisible(s, 1), 1)

func paintedCell*(c: Color): Style =
  ## The style a *completely* filled chart cell is drawn with under `solid`: the
  ## colour in the **background**, behind a space, rather than `█` in front of a
  ## background that is not the caller's to set.
  ##
  ## The two are the same picture in principle and not in practice. A background
  ## fill covers the cell box exactly, because the terminal paints it; a glyph
  ## covers as much of the box as the font's outline does, and a great many fonts
  ## draw `█` a fraction short — which shows as a hairline of the terminal's own
  ## background at every cell edge, so a bar reads as a column of separate blocks
  ## and two neighbouring columns of a chart have a seam between them. Nothing
  ## about the terminal or the library can close that gap: the ink is the font's.
  ##
  ## Only a *full* cell can be painted this way. A partial one — the top cell of
  ## a bar, every cell of a rising sparkline — has to stay a glyph, since that is
  ## where the sub-cell height lives, and its own edges are the bar's edge rather
  ## than a join between two filled cells.
  ##
  ## Attributes are dropped rather than carried over from a bar's style: `aBold`
  ## means nothing to a space, and `aUnderline` or `aStrike` would draw a rule
  ## through the cell this exists to fill evenly.
  Style().bg(c)

proc sparkLevels(values: openArray[float], width: int):
    tuple[pad: int, levels: seq[int]] =
  ## Glyph indices (0..7) for the trailing `width` values, plus the left padding
  ## that right-aligns them. Shared so the plain and coloured sparklines cannot
  ## drift apart in how they scale. A gap is level -1 and is left out of the
  ## scale, so one bad sample does not rescale the whole line.
  let start = max(values.len - width, 0)
  var
    lo = Inf
    hi = NegInf
  for i in start ..< values.len:
    if values[i].isGap: continue
    lo = min(lo, values[i])
    hi = max(hi, values[i])
  let span = max(hi - lo, 1e-9)
  result.pad = max(width - (values.len - start), 0)
  result.levels = newSeqOfCap[int](values.len - start)
  for i in start ..< values.len:
    result.levels.add(
      if values[i].isGap: -1
      else: clamp((((values[i] - lo) / span) * 7.0).round.int, 0, 7))

proc sparkline*(values: openArray[float], width: int, absent = " "): string =
  ## The most recent `width` values as a single line of block glyphs, scaled to
  ## the range of those values. Padded on the left when there are fewer values
  ## than columns, so the line grows rightwards as data arrives.
  ##
  ## A value that `isGap`_ is drawn as `absent` and kept out of the scale. The
  ## default is a space, which is what a gap looks like; pass something visible —
  ## `"░"`, `"·"` — where a hole in the middle of a run has to be told apart from
  ## the padding at the left, since both are blank. Whatever is passed is cut or
  ## padded to one column.
  if width <= 0 or values.len == 0: return ""
  let
    (pad, levels) = sparkLevels(values, width)
    gap = oneColumn(absent)
  # Every glyph is a 3-byte rune, so the final size is known up front.
  result = newStringOfCap(width * 3)
  result.add spaces(pad)
  for lv in levels:
    result.add(if lv < 0: gap else: SparkChars[lv])

proc sparkline*(values: openArray[float], width: int, colours: Gradient,
                absent = " ", solid = true): string =
  ## `sparkline` with each glyph coloured by its own height, so the colour says
  ## the same thing as the glyph and a tall spike is legible at a glance even
  ## where the eighth-block steps are hard to tell apart.
  ##
  ## `solid` paints a full-height cell as a space with the colour behind it
  ## rather than as `█` in front of it — see `paintedCell`_.
  if width <= 0 or values.len == 0: return ""
  let
    (pad, levels) = sparkLevels(values, width)
    gap = oneColumn(absent)
    paint = solid and colorProfile() != cpNoColor
  var line: Spans
  if pad > 0: line.add spaces(pad)
  # A glyph's colour depends only on its level, and there are eight of those, so
  # each is sampled at most once however wide the sparkline is — the same
  # reasoning `barChart` applies to its columns, and it matters more since Oklab:
  # `at` is a perceptual mix, not three multiplications. Filled lazily rather
  # than up front because a sparkline can be narrower than eight cells.
  #
  # `ckDefault` is the zero value and is not a colour a ramp samples to unless
  # one of its stops is one, so it doubles as "not computed yet" and the cache
  # needs no flags beside it. A gradient that does contain `ckDefault` simply
  # recomputes that level, which is correct and no slower than before.
  var sampled: array[8, Color]
  for lv in levels:
    if lv < 0:
      line.add gap                     # a gap has no height, so no colour
      continue
    if sampled[lv].kind == ckDefault: sampled[lv] = colours.at(lv.float / 7.0)
    if paint and lv == SparkChars.high:
      line.add(" ", paintedCell(sampled[lv]))
    else:
      line.add(SparkChars[lv], Style().fg(sampled[lv]))
  line.render()

proc chartNorms(values: openArray[float], start: int, lo, hi: float,
                flatLevel: float): seq[float] =
  ## Each of `values[start .. ^1]` scaled to 0..1 under the `barChart` rules.
  ##
  ## Shared by the plain and coloured charts: the flat-series special case below
  ## is subtle enough that two copies of it would not stay the same for long.
  ##
  ## `flatLevel` is what an auto-scaled series with no range comes out as, and is
  ## the one thing the bar charts and the line charts disagree about. A bar of
  ## zero height is *blank*, so a flatline has to be lifted to the shortest
  ## visible bar or it looks like no data; a line at zero is a line along the
  ## bottom row, already visible, so `lineChart` passes 0.0 and leaves it there.
  ##
  ## A value that `isGap`_ comes back as a gap: it is left out of the auto-scale,
  ## and it stays a gap under a fixed scale too, where there is no scale for it to
  ## affect but still nothing to draw.
  var
    low = lo
    high = hi
    flat = false
  if low == high:
    low = Inf
    high = NegInf
    for i in start ..< values.len:
      if values[i].isGap: continue
      low = min(low, values[i])
      high = max(high, values[i])
    if low > high: (low, high) = (0.0, 1.0)      # nothing to draw
    elif low == high: flat = true
  let span = max(high - low, 1e-9)
  result = newSeqOfCap[float](values.len - start)
  for i in start ..< values.len:
    # An auto-scaled series with no range has nothing to scale against, so every
    # value comes out at zero and the chart is drawn at `flatLevel` instead.
    result.add(if values[i].isGap: NaN
               elif flat: flatLevel
               else: clamp((values[i] - low) / span, 0.0, 1.0))

proc barChart*(values: openArray[float], width, height: int,
               lo = 0.0, hi = 0.0, absent = " "): seq[string] =
  ## A column chart `height` rows tall, one column per value, most recent last.
  ##
  ## Each cell resolves an eighth of a row, so a 6-row chart has 48 levels.
  ## Pass `lo`/`hi` to fix the scale; leaving them equal auto-scales to the data.
  ## A fixed scale keeps several charts comparable and stops one rescaling itself
  ## on every sample.
  ##
  ## An auto-scaled series with no range — one sample, or a constant — has nothing
  ## to scale against, and is drawn as the shortest visible bar rather than as an
  ## empty chart, so a flatline is distinguishable from no data. Under a *fixed*
  ## scale a value equal to `lo` is genuinely zero-height and stays blank.
  ##
  ## A value that `isGap`_ is drawn as `absent` in every row and kept out of the
  ## scale. That is the distinction a blank column cannot make on its own: a bar
  ## at the bottom of the scale is blank too.
  if width <= 0 or height <= 0: return @[]
  let
    start = max(values.len - width, 0)
    norms = chartNorms(values, start, lo, hi, 1.0 / (height * 8).float)
    pad = max(width - norms.len, 0)
    gap = oneColumn(absent)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let floorEighths = (height - 1 - row) * 8
    var line = newStringOfCap(pad + norms.len * 3)
    line.add spaces(pad)
    for n in norms:
      if n.isGap:
        line.add gap
        continue
      let eighths = clamp((n * (height * 8).float).round.int - floorEighths, 0, 8)
      line.add(if eighths == 0: " " else: SparkChars[eighths - 1])
    result.add line

proc barChart*(values: openArray[float], width, height: int, colours: Gradient,
               lo = 0.0, hi = 0.0, absent = " ", solid = true): seq[string] =
  ## `barChart` with each column coloured by its own value, so a bar's height
  ## and its colour carry the same information — which is what keeps a chart
  ## readable once it is only a few rows tall.
  ##
  ## `solid` paints the whole cells of a bar with the colour in the background
  ## rather than drawing `█` in front — see `paintedCell`_, which is where the
  ## seam that removes is described. The topmost cell of a bar keeps its glyph
  ## either way, since that is what says how far up the cell the bar got.
  if width <= 0 or height <= 0: return @[]
  let
    start = max(values.len - width, 0)
    norms = chartNorms(values, start, lo, hi, 1.0 / (height * 8).float)
    pad = max(width - norms.len, 0)
    gap = oneColumn(absent)
    paint = solid and colorProfile() != cpNoColor
  # Sampled once for the whole chart rather than per cell: the same column has
  # the same colour in every row, so re-deriving it `height` times is wasted.
  # A gap has no value to sample at, and `at(NaN)` is not a question with an
  # answer — the render loop tests for one before reading this.
  var colColours = newSeqOfCap[Color](norms.len)
  for n in norms: colColours.add(if n.isGap: Color() else: colours.at(n))
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let floorEighths = (height - 1 - row) * 8
    var line: Spans
    if pad > 0: line.add spaces(pad)
    for i, n in norms:
      if n.isGap:
        line.add gap
        continue
      let eighths = clamp((n * (height * 8).float).round.int - floorEighths, 0, 8)
      if eighths == 0:
        line.add " "
      elif eighths == 8 and paint:
        line.add(" ", paintedCell(colColours[i]))
      else:
        line.add(SparkChars[eighths - 1], Style().fg(colColours[i]))
    result.add line.render()

proc barChart*(values: openArray[float], width, height: int, bar: Style,
               lo = 0.0, hi = 0.0, absent = " ", solid = true): seq[string] =
  ## `barChart` in one colour, drawn by the widget rather than by the caller.
  ##
  ## The same chart as the plain overload with `bar.render` applied to each row,
  ## except that under `solid` a whole cell is painted with `bar`'s *foreground*
  ## as its background — which is the seam `paintedCell`_ describes, and is not
  ## something a caller styling a finished row can do for itself, since by then
  ## the full cells and the partial ones are indistinguishable glyphs.
  ##
  ## A `bar` with no foreground colour has nothing to paint with, so that case
  ## falls back to the glyphs whatever `solid` says.
  if width <= 0 or height <= 0: return @[]
  let
    start = max(values.len - width, 0)
    norms = chartNorms(values, start, lo, hi, 1.0 / (height * 8).float)
    pad = max(width - norms.len, 0)
    gap = oneColumn(absent)
    paint = solid and bar.fgc.kind != ckDefault and colorProfile() != cpNoColor
    filled = paintedCell(bar.fgc)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let floorEighths = (height - 1 - row) * 8
    var line: Spans
    if pad > 0: line.add spaces(pad)
    for n in norms:
      if n.isGap:
        line.add gap
        continue
      let eighths = clamp((n * (height * 8).float).round.int - floorEighths, 0, 8)
      if eighths == 0:
        line.add " "
      elif eighths == 8 and paint:
        line.add(" ", filled)
      else:
        line.add(SparkChars[eighths - 1], bar)
    result.add line.render()

type
  PlotGlyphs* = enum
    ## Which glyph a plotted cell is drawn with, and so how finely `lineChart`
    ## divides one — the whole difference between the five is resolution and
    ## how likely the terminal's font is to have them.
    pgBraille   ## 2x4 dots, `U+2800`..`U+28FF`. The most detail per cell.
    pgBlocks    ## 2x2 quadrant blocks. Coarser, in every font that draws borders.
    pgAscii     ## 1x1, a `*` per cell. Nothing to be missing.
    pgSextant   ## 2x3 sextant blocks. Between the two above, and *solid*: the
                ## pseudo-pixels are packed edge to edge, where braille dots
                ## leave a visible gap between one cell and the next. Unicode
                ## 13's Symbols for Legacy Computing, so newer than braille and
                ## in fewer fonts.
    pgOctant    ## 2x4 octant blocks — braille's resolution drawn solid.
                ## Unicode 16's Symbols for Legacy Computing *Supplement*, added
                ## in 2024, so this is the one most likely to come out as
                ## replacement characters. `pgSextant` is the safer solid set
                ## and `pgBraille` the safer 2x4 one; this is both at once, for
                ## a terminal known to have it.

const
  QuadrantGlyphs* = [" ", "▘", "▝", "▀", "▖", "▌", "▞", "▛",
                     "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█"]
    ## The sixteen 2x2 quadrant combinations, indexed by a bit mask counting
    ## `1` top left, `2` top right, `4` bottom left, `8` bottom right.
  SextantGlyphs* = [
    " ", "🬀", "🬁", "🬂", "🬃", "🬄", "🬅", "🬆", "🬇", "🬈", "🬉", "🬊", "🬋", "🬌", "🬍", "🬎",
    "🬏", "🬐", "🬑", "🬒", "🬓", "▌", "🬔", "🬕", "🬖", "🬗", "🬘", "🬙", "🬚", "🬛", "🬜", "🬝",
    "🬞", "🬟", "🬠", "🬡", "🬢", "🬣", "🬤", "🬥", "🬦", "🬧", "▐", "🬨", "🬩", "🬪", "🬫", "🬬",
    "🬭", "🬮", "🬯", "🬰", "🬱", "🬲", "🬳", "🬴", "🬵", "🬶", "🬷", "🬸", "🬹", "🬺", "🬻", "█"]
    ## The sixty-four 2x3 sextant combinations, indexed by the same row-major
    ## mask `lineMasks` builds — bit `sy * 2 + sx`, so `1` is the top left.
    ##
    ## The four whose picture already existed are the older glyphs rather than
    ## new ones: nothing, `▌`, `▐` and `█`. That is why this is a table and not
    ## `U+1FB00 + mask` — the block has sixty entries, not sixty-four.
  OctantGlyphs* = [
    " ", "𜺨", "𜺫", "🮂", "𜴀", "▘", "𜴁", "𜴂", "𜴃", "𜴄", "▝", "𜴅", "𜴆", "𜴇", "𜴈", "▀",
    "𜴉", "𜴊", "𜴋", "𜴌", "🯦", "𜴍", "𜴎", "𜴏", "𜴐", "𜴑", "𜴒", "𜴓", "𜴔", "𜴕", "𜴖", "𜴗",
    "𜴘", "𜴙", "𜴚", "𜴛", "𜴜", "𜴝", "𜴞", "𜴟", "🯧", "𜴠", "𜴡", "𜴢", "𜴣", "𜴤", "𜴥", "𜴦",
    "𜴧", "𜴨", "𜴩", "𜴪", "𜴫", "𜴬", "𜴭", "𜴮", "𜴯", "𜴰", "𜴱", "𜴲", "𜴳", "𜴴", "𜴵", "🮅",
    "𜺣", "𜴶", "𜴷", "𜴸", "𜴹", "𜴺", "𜴻", "𜴼", "𜴽", "𜴾", "𜴿", "𜵀", "𜵁", "𜵂", "𜵃", "𜵄",
    "▖", "𜵅", "𜵆", "𜵇", "𜵈", "▌", "𜵉", "𜵊", "𜵋", "𜵌", "▞", "𜵍", "𜵎", "𜵏", "𜵐", "▛",
    "𜵑", "𜵒", "𜵓", "𜵔", "𜵕", "𜵖", "𜵗", "𜵘", "𜵙", "𜵚", "𜵛", "𜵜", "𜵝", "𜵞", "𜵟", "𜵠",
    "𜵡", "𜵢", "𜵣", "𜵤", "𜵥", "𜵦", "𜵧", "𜵨", "𜵩", "𜵪", "𜵫", "𜵬", "𜵭", "𜵮", "𜵯", "𜵰",
    "𜺠", "𜵱", "𜵲", "𜵳", "𜵴", "𜵵", "𜵶", "𜵷", "𜵸", "𜵹", "𜵺", "𜵻", "𜵼", "𜵽", "𜵾", "𜵿",
    "𜶀", "𜶁", "𜶂", "𜶃", "𜶄", "𜶅", "𜶆", "𜶇", "𜶈", "𜶉", "𜶊", "𜶋", "𜶌", "𜶍", "𜶎", "𜶏",
    "▗", "𜶐", "𜶑", "𜶒", "𜶓", "▚", "𜶔", "𜶕", "𜶖", "𜶗", "▐", "𜶘", "𜶙", "𜶚", "𜶛", "▜",
    "𜶜", "𜶝", "𜶞", "𜶟", "𜶠", "𜶡", "𜶢", "𜶣", "𜶤", "𜶥", "𜶦", "𜶧", "𜶨", "𜶩", "𜶪", "𜶫",
    "▂", "𜶬", "𜶭", "𜶮", "𜶯", "𜶰", "𜶱", "𜶲", "𜶳", "𜶴", "𜶵", "𜶶", "𜶷", "𜶸", "𜶹", "𜶺",
    "𜶻", "𜶼", "𜶽", "𜶾", "𜶿", "𜷀", "𜷁", "𜷂", "𜷃", "𜷄", "𜷅", "𜷆", "𜷇", "𜷈", "𜷉", "𜷊",
    "𜷋", "𜷌", "𜷍", "𜷎", "𜷏", "𜷐", "𜷑", "𜷒", "𜷓", "𜷔", "𜷕", "𜷖", "𜷗", "𜷘", "𜷙", "𜷚",
    "▄", "𜷛", "𜷜", "𜷝", "𜷞", "▙", "𜷟", "𜷠", "𜷡", "𜷢", "▟", "𜷣", "▆", "𜷤", "𜷥", "█"]
    ## The two hundred and fifty-six 2x4 octant combinations, indexed by the
    ## same row-major mask. Braille's resolution with no gap between cells.
    ##
    ## Twenty-two of them are older glyphs — the quadrants, the halves and the
    ## quarter-height blocks — for the reason the sextant table has four, and
    ## which the `static:` block below turns into a check on the transcription.
  BrailleDotBits = [0x01'u8, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80]
    ## The braille dot bit for each of the eight sub-cells, in the same
    ## left-to-right then top-to-bottom order the masks below are built in.
    ## Braille numbers its dots down the left column and then down the right,
    ## with 7 and 8 added later at the bottom, so this table is not a shift.

static:
  # Two hand-transcribed tables, and a wrong entry in either is invisible
  # downstream — the chart comes out exactly as wide and as tall, drawing a
  # different picture. Same reasoning as `boxdraw`'s and `digits`' `static:`
  # blocks, and checked the same three ways: every glyph is one column, no two
  # masks share a glyph, and the entries whose picture already had a codepoint
  # agree with the table that already holds it.
  for g in SextantGlyphs:
    doAssert displayWidth(g) == 1, "sextant glyph is not one column: " & g
  for g in OctantGlyphs:
    doAssert displayWidth(g) == 1, "octant glyph is not one column: " & g
  for i, a in SextantGlyphs:
    for j in i + 1 ..< SextantGlyphs.len:
      doAssert a != SextantGlyphs[j], "sextants " & $i & " and " & $j & " agree"
  for i, a in OctantGlyphs:
    for j in i + 1 ..< OctantGlyphs.len:
      doAssert a != OctantGlyphs[j], "octants " & $i & " and " & $j & " agree"
  # An octant whose four sub-rows agree in pairs is a quadrant, and there is one
  # glyph for that picture rather than two. This is the strongest check
  # available on the octant table: sixteen entries spread across it, each of
  # which has to land in the slot the mask arithmetic says it does — so a
  # transposition anywhere near one of them fails the build.
  for q in 0 .. 15:
    let
      top = (q and 1) or ((q shr 1) and 1) shl 1
      bottom = ((q shr 2) and 1) or ((q shr 3) and 1) shl 1
      mask = top or (top shl 2) or (bottom shl 4) or (bottom shl 6)
    doAssert OctantGlyphs[mask] == QuadrantGlyphs[q],
      "octant " & $mask & " should be quadrant " & $q
  # And one whose rows are wholly on or off from the bottom up is an eighth
  # block: a 2x4 row is two eighths of the cell.
  for rows in 1 .. 4:
    var mask = 0
    for r in 4 - rows ..< 4: mask = mask or (0b11 shl (r * 2))
    doAssert OctantGlyphs[mask] == SparkChars[rows * 2 - 1],
      "octant " & $mask & " should be " & SparkChars[rows * 2 - 1]
  doAssert SextantGlyphs[0] == " " and OctantGlyphs[0] == " "
  doAssert SextantGlyphs[0b010101] == "▌" and SextantGlyphs[0b101010] == "▐"
  doAssert OctantGlyphs[0b01010101] == "▌" and OctantGlyphs[0b10101010] == "▐"

func dotsX*(g: PlotGlyphs): int =
  ## Sub-columns per cell: how many values `lineChart` fits in one column.
  if g == pgAscii: 1 else: 2

func dotsY*(g: PlotGlyphs): int =
  ## Sub-rows per cell: how many distinct heights `lineChart` resolves per row.
  case g
  of pgBraille, pgOctant: 4
  of pgSextant: 3
  of pgBlocks: 2
  of pgAscii: 1

proc addGlyph(dest: var string, g: PlotGlyphs, mask: int) =
  ## Append the one glyph that draws `mask`, the set sub-cells of a single cell.
  case g
  of pgBraille:
    if mask == 0:
      dest.add ' '                     # not U+2800, which some fonts box
    else:
      var bits = 0'u8
      for i in 0 .. 7:
        if (mask and (1 shl i)) != 0: bits = bits or BrailleDotBits[i]
      # `U+2800 + bits` as its three UTF-8 bytes rather than via `$Rune(…)`,
      # which allocates a string per cell on a path that runs width*height times.
      dest.add '\xE2'
      dest.add chr(0xA0 + (bits.int shr 6))
      dest.add chr(0x80 + (bits.int and 0x3F))
  of pgBlocks: dest.add QuadrantGlyphs[mask and 0xF]
  of pgSextant: dest.add SextantGlyphs[mask and 0x3F]
  of pgOctant: dest.add OctantGlyphs[mask and 0xFF]
  of pgAscii: dest.add(if mask == 0: ' ' else: '*')

proc lineMasks(values: openArray[float], width, height: int, lo, hi: float,
               glyphs: PlotGlyphs, fill = false): seq[int] =
  ## One sub-cell bit mask per cell, row major from the top left, for the
  ## trailing `width * dotsX` values.
  ##
  ## Bit `sy * dotsX + sx`, so the lowest set bit of a mask is its topmost
  ## sub-row — which is what the coloured overload reads to colour a cell.
  ##
  ## `fill` carries each column on down to the bottom row instead of stopping at
  ## the trace, which is an area chart. The lowest set bit is unmoved by that, so
  ## the colouring above still follows the trace rather than the fill.
  let
    dx = dotsX(glyphs)
    dy = dotsY(glyphs)
    cols = width * dx
    rows = height * dy
    start = max(values.len - cols, 0)
    norms = chartNorms(values, start, lo, hi, 0.0)
    pad = max(cols - norms.len, 0)
  result = newSeq[int](width * height)
  var prev = -1
  for i, n in norms:
    # A gap breaks the trace: nothing is drawn in its column, and `prev` is
    # dropped so the next value is not joined to the one before the hole. Drawing
    # that step would state a slope across missing data, which is the one thing a
    # line says that a bar does not.
    if n.isGap:
      prev = -1
      continue
    let
      px = pad + i
      # `rows - 1`, not `rows`: this is where the line *is*, so the top and
      # bottom sub-rows are both reachable. A bar is a quantity and rounds
      # against `rows`, which is why the two cannot share this.
      y = rows - 1 - clamp((n * (rows - 1).float).round.int, 0, rows - 1)
      top = if prev < 0: y else: min(prev, y)
      bottom = if fill: rows - 1
               elif prev < 0: y
               else: max(prev, y)
    # The whole step from the previous value is drawn in this column, so the
    # trace is connected rather than a row of dots with gaps where it climbed.
    for py in top .. bottom:
      let cell = (py div dy) * width + px div dx
      result[cell] = result[cell] or (1 shl ((py mod dy) * dx + px mod dx))
    prev = y

proc lineChart*(values: openArray[float], width, height: int,
                lo = 0.0, hi = 0.0, glyphs = pgBraille,
                fill = false): seq[string] =
  ## The values as a connected trace `height` rows tall, most recent last.
  ##
  ## The same data and the same scaling as `barChart`, drawn as a line instead of
  ## as columns: what a cell says is where the value went, not how big it was. A
  ## glyph that divides the cell is what makes that possible, so the chart holds
  ## `width * dotsX(glyphs)` values — twice a `sparkline`'s at the same width for
  ## the two braille sets — and resolves `height * dotsY(glyphs)` heights.
  ##
  ## Pass `lo`/`hi` to fix the scale; leaving them equal auto-scales to the data.
  ## Unlike `barChart` a flat series needs no special case, since a line along the
  ## bottom row is already visible.
  ##
  ## `fill` fills from the trace down to the bottom, which is an area chart: the
  ## same shape reading as a quantity rather than as a path, and the middle
  ## ground between this and `barChart` — a filled region with a sub-cell edge.
  ##
  ## A value that `isGap`_ breaks the line rather than being drawn through.
  if width <= 0 or height <= 0: return @[]
  let masks = lineMasks(values, width, height, lo, hi, glyphs, fill)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    var line = newStringOfCap(width * 3)
    for col in 0 ..< width:
      line.addGlyph(glyphs, masks[row * width + col])
    result.add line

proc lineChart*(values: openArray[float], width, height: int, colours: Gradient,
                lo = 0.0, hi = 0.0, glyphs = pgBraille,
                fill = false): seq[string] =
  ## `lineChart` with each cell coloured by the highest the trace reached in it,
  ## which is what the glyph in that cell already says — the same relation
  ## `sparkline`'s gradient keeps, and the reason a two-row chart is still
  ## readable once the glyph steps are too small to tell apart.
  if width <= 0 or height <= 0: return @[]
  let
    dx = dotsX(glyphs)
    dy = dotsY(glyphs)
    rows = height * dy
    span = max(rows - 1, 1).float
    masks = lineMasks(values, width, height, lo, hi, glyphs, fill)
  result = newSeqOfCap[string](height)
  var
    cell = newStringOfCap(3)
    # One sample per *height*, not per cell: a chart has `rows` of those and up
    # to `width * height` cells. Lazy, and `ckDefault` as the "not computed"
    # sentinel, for the reasons spelled out on `sparkline` above.
    sampled = newSeq[Color](rows)
  for row in 0 ..< height:
    var line: Spans
    for col in 0 ..< width:
      let mask = masks[row * width + col]
      if mask == 0:
        line.add " "
        continue
      var bit = 0
      while (mask and (1 shl bit)) == 0: inc bit
      let y = row * dy + bit div dx
      if sampled[y].kind == ckDefault:
        sampled[y] = colours.at((rows - 1 - y).float / span)
      cell.setLen 0
      cell.addGlyph(glyphs, mask)
      line.add(cell, Style().fg(sampled[y]))
    result.add line.render()

proc lineSpark*(values: openArray[float], width: int, lo = 0.0, hi = 0.0,
                glyphs = pgBraille, fill = false): string =
  ## A one-row `lineChart`: `sparkline`'s shape, drawn as a trace.
  ##
  ## Four heights and two values per cell under `pgBraille`, against a
  ## `sparkline`'s eight heights and one value — so this says less about a single
  ## value and more about the shape of the run, which is usually what a chart
  ## squeezed into one row is being asked.
  ##
  ## One row is where the glyph set matters most: `pgBlocks` has two heights to
  ## work with and `pgAscii` has one, which makes an ascii `lineSpark` a solid
  ## row of `*`. Those two want rows; only braille says anything in a single one.
  ##
  ## `fill` is the same one row filled from the trace down, which at this height
  ## is a `sparkline` with the top edge resolved in both directions instead of
  ## just in height — four steps up and two values across, against eight steps
  ## and one value, under `pgBraille`.
  let rows = lineChart(values, width, 1, lo, hi, glyphs, fill)
  if rows.len > 0: rows[0] else: ""

proc lineSpark*(values: openArray[float], width: int, colours: Gradient,
                lo = 0.0, hi = 0.0, glyphs = pgBraille,
                fill = false): string =
  ## `lineSpark` with each cell coloured by the highest the trace reached in it.
  let rows = lineChart(values, width, 1, colours, lo, hi, glyphs, fill)
  if rows.len > 0: rows[0] else: ""

proc spinner*(frame: int): string =
  ## One frame of a spinner, one column wide. Advance `frame` on a timer; it
  ## wraps in both directions, so it never needs resetting and a frame derived
  ## from a signed delta is fine.
  # `floorMod`, not `mod`: Nim's `mod` keeps the sign of the dividend, so a
  # negative frame would index backwards out of the array.
  SpinnerFrames[floorMod(frame, SpinnerFrames.len)]

proc pulse*(colours: Gradient, phase: float, cells = 5, glyph = "●",
            spread = 0.125): string =
  ## A spinner whose motion is in the colour rather than in the glyph: `cells`
  ## identical dots, each sampling `colours` a little behind the one before it,
  ## so a bright point travels along the row.
  ##
  ## `phase` is a position in the cycle rather than a frame index — it wraps at
  ## 1.0 and only its fractional part is used, so `epochTime() * rate` can be
  ## passed straight in and a redraw at any rate looks the same. That is the
  ## difference from `spinner`_, which advances one discrete frame at a time
  ## because it has ten of them and no others.
  ##
  ## Each dot's brightness eases as `(1 - x)²` over its own cycle, which is what
  ## makes the trail fall away behind the point instead of stepping down evenly.
  ## `spread` is the stagger between neighbouring dots as a fraction of the
  ## cycle; at the default five dots cover five eighths of it, so there is always
  ## a gap for the point to travel into.
  ##
  ## Under `cpNoColor` there is no motion left — every cell is the same glyph —
  ## so it falls back to `spinner`_ padded to the same width. Changing width with
  ## the profile would move whatever is laid out beside it, which is a worse
  ## failure than a plainer spinner.
  if cells <= 0: return ""
  if colorProfile() == cpNoColor:
    let frame = int(floorMod(phase, 1.0) * SpinnerFrames.len.float)
    return spinner(frame) & spaces(cells - 1)
  var line: Spans
  for i in 0 ..< cells:
    # `floorMod`, not `mod`: `phase - i * spread` goes negative for the dots
    # behind the point, and Nim's `mod` keeps the sign of the dividend.
    let x = floorMod(phase - i.float * spread, 1.0)
    line.add(glyph, Style().fg(colours.at((1.0 - x) * (1.0 - x))))
  line.render()

proc keyHint*(key, desc: string): string =
  ## `key desc` with the key emphasised, for footer help lines.
  Style().bold().render(key) & " " & Style().faint().render(desc)

proc hints*(pairs: openArray[(string, string)], sep = "  "): string =
  ## Several `keyHint`s joined by a faint separator: `q quit · space pause`.
  var parts: seq[string]
  for (k, d) in pairs: parts.add keyHint(k, d)
  parts.join(Style().faint().render(sep & "·" & sep))

proc tabBar*(labels: openArray[string], active: int, width = 0,
             activeStyle = Style().bold(), inactiveStyle = Style().faint(),
             sep = "│"): string =
  ## A row of tabs with one of them marked active.
  ##
  ## Each label is padded with a space on either side, so the active tab's
  ## highlight — usually a background colour — has room to read as a tab rather
  ## than as coloured text. A `width` above 0 pads or truncates the whole strip
  ## to exactly that many columns, which is what a full-width header wants.
  var line: Spans
  for i, label in labels:
    if i > 0: line.add(sep, inactiveStyle)
    line.add(" " & label & " ", if i == active: activeStyle else: inactiveStyle)
  if width > 0: line = line.fit(width)
  line.render()

proc statusBar*(left, center, right: string, width: int,
                style = Style()): string =
  ## Three segments across exactly `width` columns: `left` flush left, `right`
  ## flush right, `center` centred on the bar as a whole.
  ##
  ## Centred against the full width rather than against the gap between the
  ## other two, so the middle segment does not shuffle sideways every time the
  ## left one changes length — a clock that drifts as the path beside it grows
  ## is worse than one slightly off centre. When the three cannot all fit the
  ## centre is dropped first, then the right is truncated, then the left: the
  ## leftmost segment is the one most likely to say where you are.
  ##
  ## The three segments are flattened onto one line — a status bar is where a
  ## path, a branch name or a message from somewhere else ends up, and a newline
  ## in one would make this two bars. Unlike the rest of the widgets here it
  ## measures and concatenates raw strings rather than building a `Spans`, so it
  ## does not inherit that module's guarantee and has to make it itself.
  if width <= 0: return ""
  var
    l = oneLine(left)
    c = oneLine(center)
    r = oneLine(right)
    lw = displayWidth(l)
    cw = displayWidth(c)
    rw = displayWidth(r)
  if lw + cw + rw > width:
    c = ""
    cw = 0
  if lw + rw > width:
    r = truncateVisible(r, max(width - lw, 0))
    rw = displayWidth(r)
  if lw > width:
    l = truncateVisible(l, width)
    lw = width
  let start = clamp((width - cw) div 2, lw, max(width - rw - cw, lw))
  result = l & spaces(max(start - lw, 0)) & c &
           spaces(max(width - rw - start - cw, 0)) & r
  # `renderOver`, since the three segments are the caller's and a status bar
  # segment is one of the likeliest things in the library to arrive already
  # coloured. Under `render` a reset in `left` ends the bar's background for
  # every column after it, which reads as the bar stopping half way across.
  if not style.isEmpty: result = style.renderOver(result)
