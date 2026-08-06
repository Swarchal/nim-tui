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
## That argument is required rather than defaulted, so the uncoloured calls above
## stay unambiguous — a `Gradient` with a default value would make `gauge(0.5, 20)`
## match both overloads.

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
            emptyStyle = Style().faint(), full = "█"): string =
  ## `gauge` with the filled cells coloured along `fill`.
  ##
  ## The ramp is laid over the *whole* bar, not over the filled part, so a given
  ## column is always the same colour whatever the current value. Ramping over
  ## the filled part instead would recolour every cell on each update, which
  ## reads as the bar flashing rather than growing — and would make 100% of a
  ## `HeatGradient` look identical to 10% of it.
  if width <= 0: return ""
  let
    f = clamp(fraction, 0.0, 1.0)
    exact = f * width.float
    whole = min(exact.int, width)
    rest = exact - exact.int.float
    colours = fill.ramp(width)
  var line: Spans
  for i in 0 ..< whole:
    line.add(full, Style().fg(colours[i]))
  var used = whole
  if used < width:
    let eighth = (rest * 8).int
    if eighth > 0:
      line.add(PartialBlocks[eighth], Style().fg(colours[used]))
      inc used
    if used < width:
      line.add(empty.repeat(width - used), emptyStyle)
  line.render()

proc sparkLevels(values: openArray[float], width: int):
    tuple[pad: int, levels: seq[int]] =
  ## Glyph indices (0..7) for the trailing `width` values, plus the left padding
  ## that right-aligns them. Shared so the plain and coloured sparklines cannot
  ## drift apart in how they scale.
  let start = max(values.len - width, 0)
  var
    lo = values[start]
    hi = values[start]
  for i in start ..< values.len:
    lo = min(lo, values[i])
    hi = max(hi, values[i])
  let span = max(hi - lo, 1e-9)
  result.pad = max(width - (values.len - start), 0)
  result.levels = newSeqOfCap[int](values.len - start)
  for i in start ..< values.len:
    result.levels.add clamp((((values[i] - lo) / span) * 7.0).round.int, 0, 7)

proc sparkline*(values: openArray[float], width: int): string =
  ## The most recent `width` values as a single line of block glyphs, scaled to
  ## the range of those values. Padded on the left when there are fewer values
  ## than columns, so the line grows rightwards as data arrives.
  if width <= 0 or values.len == 0: return ""
  let (pad, levels) = sparkLevels(values, width)
  # Every glyph is a 3-byte rune, so the final size is known up front.
  result = newStringOfCap(width * 3)
  result.add spaces(pad)
  for lv in levels:
    result.add SparkChars[lv]

proc sparkline*(values: openArray[float], width: int, colours: Gradient): string =
  ## `sparkline` with each glyph coloured by its own height, so the colour says
  ## the same thing as the glyph and a tall spike is legible at a glance even
  ## where the eighth-block steps are hard to tell apart.
  if width <= 0 or values.len == 0: return ""
  let (pad, levels) = sparkLevels(values, width)
  var line: Spans
  if pad > 0: line.add spaces(pad)
  for lv in levels:
    line.add(SparkChars[lv], Style().fg(colours.at(lv.float / 7.0)))
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
  var
    low = lo
    high = hi
    flat = false
  if low == high:
    low = Inf
    high = NegInf
    for i in start ..< values.len:
      low = min(low, values[i])
      high = max(high, values[i])
    if low > high: (low, high) = (0.0, 1.0)      # nothing to draw
    elif low == high: flat = true
  let span = max(high - low, 1e-9)
  result = newSeqOfCap[float](values.len - start)
  for i in start ..< values.len:
    # An auto-scaled series with no range has nothing to scale against, so every
    # value comes out at zero and the chart is drawn at `flatLevel` instead.
    result.add(if flat: flatLevel
               else: clamp((values[i] - low) / span, 0.0, 1.0))

proc barChart*(values: openArray[float], width, height: int,
               lo = 0.0, hi = 0.0): seq[string] =
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
  if width <= 0 or height <= 0: return @[]
  let
    start = max(values.len - width, 0)
    norms = chartNorms(values, start, lo, hi, 1.0 / (height * 8).float)
    pad = max(width - norms.len, 0)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let floorEighths = (height - 1 - row) * 8
    var line = newStringOfCap(pad + norms.len * 3)
    line.add spaces(pad)
    for n in norms:
      let eighths = clamp((n * (height * 8).float).round.int - floorEighths, 0, 8)
      line.add(if eighths == 0: " " else: SparkChars[eighths - 1])
    result.add line

proc barChart*(values: openArray[float], width, height: int, colours: Gradient,
               lo = 0.0, hi = 0.0): seq[string] =
  ## `barChart` with each column coloured by its own value, so a bar's height
  ## and its colour carry the same information — which is what keeps a chart
  ## readable once it is only a few rows tall.
  if width <= 0 or height <= 0: return @[]
  let
    start = max(values.len - width, 0)
    norms = chartNorms(values, start, lo, hi, 1.0 / (height * 8).float)
    pad = max(width - norms.len, 0)
  # Sampled once for the whole chart rather than per cell: the same column has
  # the same colour in every row, so re-deriving it `height` times is wasted.
  var colColours = newSeqOfCap[Color](norms.len)
  for n in norms: colColours.add colours.at(n)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let floorEighths = (height - 1 - row) * 8
    var line: Spans
    if pad > 0: line.add spaces(pad)
    for i, n in norms:
      let eighths = clamp((n * (height * 8).float).round.int - floorEighths, 0, 8)
      if eighths == 0:
        line.add " "
      else:
        line.add(SparkChars[eighths - 1], Style().fg(colColours[i]))
    result.add line.render()

type
  PlotGlyphs* = enum
    ## Which glyph a plotted cell is drawn with, and so how finely `lineChart`
    ## divides one — the whole difference between the three is resolution and
    ## how likely the terminal's font is to have them.
    pgBraille   ## 2x4 dots, `U+2800`..`U+28FF`. The most detail per cell.
    pgBlocks    ## 2x2 quadrant blocks. Coarser, in every font that draws borders.
    pgAscii     ## 1x1, a `*` per cell. Nothing to be missing.

const
  QuadrantGlyphs* = [" ", "▘", "▝", "▀", "▖", "▌", "▞", "▛",
                     "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█"]
    ## The sixteen 2x2 quadrant combinations, indexed by a bit mask counting
    ## `1` top left, `2` top right, `4` bottom left, `8` bottom right.
  BrailleDotBits = [0x01'u8, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80]
    ## The braille dot bit for each of the eight sub-cells, in the same
    ## left-to-right then top-to-bottom order the masks below are built in.
    ## Braille numbers its dots down the left column and then down the right,
    ## with 7 and 8 added later at the bottom, so this table is not a shift.

func dotsX*(g: PlotGlyphs): int =
  ## Sub-columns per cell: how many values `lineChart` fits in one column.
  if g == pgAscii: 1 else: 2

func dotsY*(g: PlotGlyphs): int =
  ## Sub-rows per cell: how many distinct heights `lineChart` resolves per row.
  case g
  of pgBraille: 4
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
  of pgAscii: dest.add(if mask == 0: ' ' else: '*')

proc lineMasks(values: openArray[float], width, height: int, lo, hi: float,
               glyphs: PlotGlyphs): seq[int] =
  ## One sub-cell bit mask per cell, row major from the top left, for the
  ## trailing `width * dotsX` values.
  ##
  ## Bit `sy * dotsX + sx`, so the lowest set bit of a mask is its topmost
  ## sub-row — which is what the coloured overload reads to colour a cell.
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
    let
      px = pad + i
      # `rows - 1`, not `rows`: this is where the line *is*, so the top and
      # bottom sub-rows are both reachable. A bar is a quantity and rounds
      # against `rows`, which is why the two cannot share this.
      y = rows - 1 - clamp((n * (rows - 1).float).round.int, 0, rows - 1)
      top = if prev < 0: y else: min(prev, y)
      bottom = if prev < 0: y else: max(prev, y)
    # The whole step from the previous value is drawn in this column, so the
    # trace is connected rather than a row of dots with gaps where it climbed.
    for py in top .. bottom:
      let cell = (py div dy) * width + px div dx
      result[cell] = result[cell] or (1 shl ((py mod dy) * dx + px mod dx))
    prev = y

proc lineChart*(values: openArray[float], width, height: int,
                lo = 0.0, hi = 0.0, glyphs = pgBraille): seq[string] =
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
  if width <= 0 or height <= 0: return @[]
  let masks = lineMasks(values, width, height, lo, hi, glyphs)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    var line = newStringOfCap(width * 3)
    for col in 0 ..< width:
      line.addGlyph(glyphs, masks[row * width + col])
    result.add line

proc lineChart*(values: openArray[float], width, height: int, colours: Gradient,
                lo = 0.0, hi = 0.0, glyphs = pgBraille): seq[string] =
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
    masks = lineMasks(values, width, height, lo, hi, glyphs)
  result = newSeqOfCap[string](height)
  var cell = newStringOfCap(3)
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
      cell.setLen 0
      cell.addGlyph(glyphs, mask)
      line.add(cell, Style().fg(colours.at((rows - 1 - y).float / span)))
    result.add line.render()

proc lineSpark*(values: openArray[float], width: int, lo = 0.0, hi = 0.0,
                glyphs = pgBraille): string =
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
  let rows = lineChart(values, width, 1, lo, hi, glyphs)
  if rows.len > 0: rows[0] else: ""

proc lineSpark*(values: openArray[float], width: int, colours: Gradient,
                lo = 0.0, hi = 0.0, glyphs = pgBraille): string =
  ## `lineSpark` with each cell coloured by the highest the trace reached in it.
  let rows = lineChart(values, width, 1, colours, lo, hi, glyphs)
  if rows.len > 0: rows[0] else: ""

proc spinner*(frame: int): string =
  ## One frame of a spinner, one column wide. Advance `frame` on a timer; it
  ## wraps in both directions, so it never needs resetting and a frame derived
  ## from a signed delta is fine.
  # `floorMod`, not `mod`: Nim's `mod` keeps the sign of the dividend, so a
  # negative frame would index backwards out of the array.
  SpinnerFrames[floorMod(frame, SpinnerFrames.len)]

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
