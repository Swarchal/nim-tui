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
## `gauge`, `sparkline` and `barChart` each take an optional `Gradient
## <color.html#Gradient>`_ as an extra argument, which colours the result by
## position or by value:
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
                height: int): seq[float] =
  ## Each of `values[start .. ^1]` scaled to 0..1 under the `barChart` rules.
  ##
  ## Shared by the plain and coloured charts: the flat-series special case below
  ## is subtle enough that two copies of it would not stay the same for long.
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
    # An auto-scaled series with no range has nothing to scale against, and
    # every value would come out at zero — an empty chart, indistinguishable
    # from no data. Draw it as the shortest visible bar instead, which is what
    # `sparkline` does with the same input.
    result.add(if flat: 1.0 / (height * 8).float
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
    norms = chartNorms(values, start, lo, hi, height)
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
    norms = chartNorms(values, start, lo, hi, height)
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
  if width <= 0: return ""
  var
    l = left
    c = center
    r = right
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
  if not style.isEmpty: result = style.render(result)
