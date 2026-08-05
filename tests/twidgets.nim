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

suite "gradient widgets":
  test "a gradient gauge is exactly as wide as a plain one":
    for w in [1, 5, 20, 40]:
      for f in [0.0, 0.01, 0.25, 0.5, 0.73, 0.999, 1.0]:
        check displayWidth(gauge(f, w, HeatGradient)) == w
        check displayWidth(gauge(f, w, HeatGradient)) == displayWidth(gauge(f, w))

  test "the gauge ramp is laid over the whole bar, not the filled part":
    # Otherwise every cell recolours as the bar grows, which reads as flashing,
    # and 100% of a heat gradient looks the same as 10% of it.
    let g = gradient(hex"#000000", hex"#ffffff")
    let short = gauge(0.1, 20, g)
    let long = gauge(0.9, 20, g)
    check short.stripAnsi[0] == long.stripAnsi[0]
    check "38;2;0;0;0" in short
    check "38;2;0;0;0" in long

  test "an empty and a full gauge are still the right width":
    check displayWidth(gauge(0.0, 10, CoolGradient)) == 10
    check displayWidth(gauge(1.0, 10, CoolGradient)) == 10
    check gauge(0.5, 0, CoolGradient) == ""

  test "a coloured sparkline matches the plain one glyph for glyph":
    let values = @[1.0, 5.0, 3.0, 9.0, 2.0, 7.0, 4.0]
    for w in [3, 7, 20]:
      check sparkline(values, w, CoolGradient).stripAnsi ==
            sparkline(values, w)
      check displayWidth(sparkline(values, w, CoolGradient)) == w

  test "a coloured barChart matches the plain one cell for cell":
    let values = @[1.0, 4.0, 9.0, 3.0, 7.0]
    let plain = barChart(values, 12, 5)
    let painted = barChart(values, 12, 5, HeatGradient)
    check painted.len == plain.len
    for i in 0 ..< plain.len:
      check painted[i].stripAnsi == plain[i]
      check displayWidth(painted[i]) == 12

  test "a coloured barChart handles the degenerate inputs the plain one does":
    check barChart(@[], 10, 4, HeatGradient).len == 4
    check barChart(@[5.0], 10, 4, HeatGradient).len == 4
    check barChart(@[5.0, 5.0], 10, 0, HeatGradient).len == 0
    for row in barChart(@[5.0, 5.0, 5.0], 10, 4, HeatGradient):
      check displayWidth(row) == 10

suite "tab bar":
  test "a width is honoured exactly":
    for w in [5, 10, 24, 60]:
      check displayWidth(tabBar(["files", "search", "help"], 1, w)) == w

  test "the active tab is the styled one":
    let bar = tabBar(["a", "b", "c"], 1, activeStyle = Style().fg(hex"#00e5ff"),
                     inactiveStyle = Style())
    check "0;229;255" in bar
    check bar.stripAnsi == " a │ b │ c "

  test "an out-of-range index simply styles nothing":
    check tabBar(["a", "b"], -1).stripAnsi == " a │ b "
    check tabBar(["a", "b"], 99).stripAnsi == " a │ b "

  test "no tabs is an empty strip, not a crash":
    check tabBar([], 0) == ""
    check displayWidth(tabBar([], 0, 20)) == 20

suite "status bar":
  test "the bar is exactly the requested width at any size":
    for w in 1 .. 60:
      check displayWidth(statusBar(" NORMAL ", "~/code/nim-tui", " 12:04 ", w)) == w

  test "the segments sit where they belong when there is room":
    let bar = statusBar("L", "C", "R", 11)
    check bar == "L    C    R"

  test "the centre is dropped first, then the right is cut":
    check statusBar("LEFT", "CENTRE", "RIGHT", 9).stripAnsi == "LEFTRIGHT"
    check displayWidth(statusBar("LEFT", "CENTRE", "RIGHT", 6)) == 6
    check statusBar("LEFT", "CENTRE", "RIGHT", 4).stripAnsi == "LEFT"

  test "double-width and styled segments measure correctly":
    for w in [20, 40]:
      check displayWidth(statusBar("日本語", "",
                                   Style().bold().render("ok"), w)) == w

  test "a zero width is empty rather than negative":
    check statusBar("a", "b", "c", 0) == ""

suite "a status bar is one bar":
  ## `statusBar` measures and concatenates raw strings instead of building a
  ## `Spans`, so it does not inherit that module's guarantee and needs its own.
  ## It is also the widget most likely to be handed text from elsewhere: a path,
  ## a branch name, the message off an exception.

  test "a newline in any segment leaves it one line, exactly as wide":
    for w in [20, 40, 80]:
      for seg in 0 .. 2:
        var parts = ["left", "centre", "right"]
        parts[seg] = "two\nlines"
        let bar = statusBar(parts[0], parts[1], parts[2], w)
        checkpoint "width " & $w & " segment " & $seg & ": " & bar
        check bar.split('\n').len == 1
        check displayWidth(bar) == w

  test "the text is still there, on the one line":
    let bar = statusBar("a\nb", "", "", 20)
    check bar.startsWith("a b")

  test "tabs do not silently widen it past the width either":
    # A tab is zero columns to `displayWidth` and eight to the terminal, so an
    # unflattened one overflows the bar rather than merely looking wrong.
    check displayWidth(statusBar("a\tb", "c", "d", 30)) == 30
