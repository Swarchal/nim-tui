import std/[unittest, strutils]
import nimtui/[ansi, widgets]

## Each widget renders to exactly the width it was asked for, whatever the data;
## the sub-cell glyphs are where that is easy to get wrong.

suite "widgets":
  test "gauge fills proportionally and keeps its width":
    check stripAnsi(gauge(0.0, 10)) == "░░░░░░░░░░"
    check stripAnsi(gauge(1.0, 10)) == "██████████"
    for f in [0.0, 0.13, 0.5, 0.77, 1.0]:
      check displayWidth(gauge(f, 20)) == 20

  test "sparkline is right-aligned and one cell per value":
    check displayWidth(sparkline(@[1.0, 2.0, 3.0], 6)) == 6
    check sparkline(@[1.0, 2.0, 3.0], 6).startsWith("   ")
    check sparkline(@[], 6) == ""

  test "barChart is exactly width x height":
    let values = @[10.0, 40.0, 90.0, 20.0]
    let rows = barChart(values, 8, 5, lo = 0.0, hi = 100.0)
    check rows.len == 5
    for r in rows: check displayWidth(r) == 8

  test "barChart draws a flat series rather than nothing":
    # Auto-scaled, so the series has no range to scale against. Every value would
    # otherwise land at zero and the chart would come back blank — a constant
    # metric indistinguishable from no data at all.
    let rows = barChart(@[3.0, 3.0, 3.0], 3, 3)
    check rows[^1] == "▁▁▁"            # shortest visible bar, as `sparkline` does
    check rows[0] == "   "
    check barChart(@[42.0], 3, 2)[^1] == "  ▁"
    check barChart(@[], 3, 2) == @["   ", "   "]     # genuinely no data

  test "barChart with a fixed scale still leaves a floor value empty":
    # A value equal to `lo` really is zero-height; only the auto-scaled no-range
    # case gets the minimum bar.
    check barChart(@[0.0], 1, 2, 0.0, 100.0) == @[" ", " "]

  test "spinner wraps in both directions":
    # Nim's `mod` keeps the sign of the dividend, so a negative frame used to
    # index backwards out of the array.
    check spinner(-1) == spinner(9)
    check spinner(-10) == spinner(0)
    check spinner(-11) == spinner(9)

  test "barChart puts taller values higher up":
    let rows = barChart(@[100.0, 10.0], 2, 4, lo = 0.0, hi = 100.0)
    check rows[0][0 ..< 3] != "  "        # top row filled for the 100 column
    check rows[0].endsWith(" ")           # but not for the 10 column
