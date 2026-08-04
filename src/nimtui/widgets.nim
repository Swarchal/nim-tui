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

import std/[strutils, math]
import ./style

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

proc sparkline*(values: openArray[float], width: int): string =
  ## The most recent `width` values as a single line of block glyphs, scaled to
  ## the range of those values. Padded on the left when there are fewer values
  ## than columns, so the line grows rightwards as data arrives.
  if width <= 0 or values.len == 0: return ""
  let start = max(values.len - width, 0)
  var lo = values[start]
  var hi = values[start]
  for i in start ..< values.len:
    lo = min(lo, values[i])
    hi = max(hi, values[i])
  let span = max(hi - lo, 1e-9)
  # Every glyph is a 3-byte rune, so the final size is known up front.
  result = newStringOfCap(width * 3)
  result.add spaces(max(width - (values.len - start), 0))
  for i in start ..< values.len:
    let norm = (values[i] - lo) / span
    result.add SparkChars[clamp((norm * 7.0).round.int, 0, 7)]

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
  let start = max(values.len - width, 0)
  var low = lo
  var high = hi
  var flat = false
  if low == high:
    low = Inf
    high = NegInf
    for i in start ..< values.len:
      low = min(low, values[i])
      high = max(high, values[i])
    if low > high: (low, high) = (0.0, 1.0)      # nothing to draw
    elif low == high: flat = true
  let span = max(high - low, 1e-9)

  let pad = max(width - (values.len - start), 0)
  result = newSeqOfCap[string](height)
  for row in 0 ..< height:
    let floorEighths = (height - 1 - row) * 8
    var line = newStringOfCap(pad + (values.len - start) * 3)
    line.add spaces(pad)
    for i in start ..< values.len:
      # An auto-scaled series with no range has nothing to scale against, and
      # every value would come out at zero — an empty chart, indistinguishable
      # from no data. Draw it as the shortest visible bar instead, which is what
      # `sparkline` does with the same input.
      let norm = if flat: 1.0 / (height * 8).float
                 else: clamp((values[i] - low) / span, 0.0, 1.0)
      let eighths = clamp((norm * (height * 8).float).round.int - floorEighths, 0, 8)
      line.add(if eighths == 0: " " else: SparkChars[eighths - 1])
    result.add line

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
