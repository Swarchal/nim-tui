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

suite "a bar whose sub-cell resolution is in the glyph":
  ## The point of `thinBar` against a gradient `gauge`: half a cell said with
  ## `╸` rather than with a second colour, so nothing about it depends on the
  ## profile. Every assertion here would still pass under `cpNoColor`, which is
  ## the claim.

  test "it is exactly as wide as it was asked for":
    for w in [1, 2, 5, 20, 41]:
      for f in [0.0, 0.01, 0.024, 0.25, 0.5, 0.73, 0.999, 1.0]:
        checkpoint "w=" & $w & " f=" & $f
        check displayWidth(thinBar(f, w)) == w
        check displayWidth(thinBar(f, w, HeatGradient)) == w

  test "the ends are the ends":
    check thinBar(0.0, 6) == "──────"
    check thinBar(1.0, 6) == "━━━━━━"
    # Clamped, not wrapped: a fraction outside 0..1 is a caller's arithmetic
    # going wrong, and a bar that came back empty for 1.2 would hide it.
    check thinBar(-0.5, 6) == thinBar(0.0, 6)
    check thinBar(1.5, 6) == thinBar(1.0, 6)

  test "a half cell is drawn as a half cell":
    # Two and a half cells of ten, which whole-cell rounding would draw as two
    # or as three. This is the resolution the widget exists for.
    check thinBar(0.25, 10) == "━━╸───────"
    check thinBar(0.2, 10) == "━━────────"
    check thinBar(0.3, 10) == "━━━───────"

  test "the last cell can be a half, and never overruns":
    # `halves` caps at `width * 2`, so an odd count always leaves a whole cell
    # for the half to sit in — the one place this could write width + 1 columns.
    for w in [1, 2, 3, 7]:
      for h in 0 .. w * 2:
        let bar = thinBar(h.float / float(w * 2), w)
        checkpoint "w=" & $w & " halves=" & $h
        check displayWidth(bar) == w
        check bar.count("╸") <= 1

  test "it says the same thing with the colour taken away":
    # A gradient `gauge` has to fall back to half the resolution here; this does
    # not, because the sub-cell information was never in the colour.
    #
    # `stripAnsi` rather than the bytes, and the difference is the point: the
    # track keeps its `faint`, since `cpNoColor` suppresses colour and not
    # attributes. What has to be identical is the *glyphs*, which is where this
    # widget keeps the half cell.
    let saved = colorProfile()
    setColorProfile(cpNoColor)
    check stripAnsi(thinBar(0.25, 10, HeatGradient)) == "━━╸───────"
    check stripAnsi(thinBar(0.25, 10, HeatGradient)) == thinBar(0.25, 10)
    check displayWidth(thinBar(0.25, 10, HeatGradient)) == 10
    setColorProfile(saved)

  test "the gradient overload colours the fill and not the track":
    let bar = thinBar(0.5, 10, gradient(hex"#ff0000", hex"#00ff00"))
    check "38;2;255;0;0" in bar        # the first cell is the first stop
    check stripAnsi(bar) == "━━━━━─────"

suite "a spinner that moves in colour":
  test "it is exactly `cells` columns, at every phase":
    for cells in [1, 3, 5, 9]:
      for i in 0 .. 12:
        checkpoint "cells=" & $cells & " i=" & $i
        check displayWidth(pulse(HeatGradient, i.float / 12.0, cells)) == cells

  test "the phase wraps, so a clock can be handed straight in":
    # `epochTime() * rate` is the intended argument and grows without bound.
    check pulse(HeatGradient, 0.25, 5) == pulse(HeatGradient, 7.25, 5)
    check pulse(HeatGradient, 0.25, 5) == pulse(HeatGradient, -0.75, 5)

  test "the dots are staggered rather than all the same colour":
    # Which is the whole widget: five identical glyphs, and the only thing
    # distinguishing them is where each is in the cycle.
    let row = pulse(HeatGradient, 0.4, 5)
    var seen: seq[string]
    for part in row.split("●"):
      if part.len > 0 and part notin seen: seen.add part
    check seen.len > 5                 # an on and an off escape per distinct dot

  test "advancing the phase changes the picture":
    var pictures: seq[string]
    for i in 0 .. 7:
      let p = pulse(HeatGradient, i.float / 8.0, 5)
      if p notin pictures: pictures.add p
    check pictures.len == 8

  test "with no colour it falls back to the glyph spinner, same width":
    # A row of identical uncoloured dots does not move at all, which is worse
    # than a plainer spinner. Changing width with the profile would be worse
    # still — whatever is laid out beside it would shift.
    let saved = colorProfile()
    setColorProfile(cpNoColor)
    for cells in [1, 5, 9]:
      check displayWidth(pulse(HeatGradient, 0.3, cells)) == cells
    check pulse(HeatGradient, 0.0, 5).startsWith(SpinnerFrames[0])
    check pulse(HeatGradient, 0.0, 5) != pulse(HeatGradient, 0.5, 5)
    setColorProfile(saved)

suite "line charts":
  ## A trace rather than columns, so the assertions that matter are the width one
  ## (a braille or quadrant glyph measured as two columns wraps the frame) and
  ## the sub-cell bit order, which nothing dimensional can see.

  const AllGlyphs = [pgBraille, pgBlocks, pgAscii]

  test "a chart is exactly width x height in every glyph set":
    let values = @[10.0, 40.0, 90.0, 20.0, 55.0, 5.0, 80.0]
    for g in AllGlyphs:
      for w in [1, 3, 8, 40]:
        for h in [1, 2, 5]:
          let rows = lineChart(values, w, h, glyphs = g)
          checkpoint $g & " " & $w & "x" & $h
          check rows.len == h
          for r in rows: check displayWidth(r) == w

  test "the degenerate inputs are a blank chart, not a crash":
    for g in AllGlyphs:
      check lineChart(@[], 4, 2, glyphs = g) == @["    ", "    "]
      check lineChart(@[5.0], 4, 2, glyphs = g).len == 2
      check lineChart(@[1.0, 2.0], 0, 2, glyphs = g).len == 0
      check lineChart(@[1.0, 2.0], 4, 0, glyphs = g).len == 0
      check lineSpark(@[], 0, glyphs = g) == ""

  test "a flat series is a line along the bottom, not a lifted one":
    # The difference from `barChart`, which has to lift a flatline off the floor
    # because a bar of zero height is blank. A line at zero is already visible.
    check lineChart(@[3.0, 3.0, 3.0], 3, 2, glyphs = pgAscii) == @["   ", "***"]
    check lineChart(@[3.0, 3.0], 1, 1) == @["⣀"]

  test "fewer values than sub-columns pad on the left":
    check lineChart(@[5.0], 4, 1, glyphs = pgAscii) == @["   *"]
    check lineSpark(@[1.0, 2.0], 4, glyphs = pgAscii) == "  **"

  test "the sub-cell bits map onto the right dots":
    # Hand-derived. Both values are in the one cell, and the step between them is
    # drawn in the *second* sub-column, so a rise is the bottom-left dot plus the
    # whole right column (U+28F8) and a fall is the top-left dot plus the same
    # (U+28B9). Getting `BrailleDotBits` wrong leaves every width check above
    # happy and draws a different picture.
    check lineChart(@[0.0, 1.0], 1, 1, lo = 0.0, hi = 1.0) == @["⣸"]
    check lineChart(@[1.0, 0.0], 1, 1, lo = 0.0, hi = 1.0) == @["⢹"]
    check lineChart(@[0.0, 1.0], 1, 1, 0.0, 1.0, pgBlocks) == @["▟"]
    check lineChart(@[1.0, 0.0], 1, 1, 0.0, 1.0, pgBlocks) == @["▜"]

  test "the top and bottom rows are both reachable":
    # A line is a position, so it rounds against `rows - 1`; a bar is a quantity
    # and rounds against `rows`. Sharing that arithmetic loses one end or other.
    let rows = lineChart(@[0.0, 100.0], 2, 3, 0.0, 100.0, pgAscii)
    check rows[0] == " *"                    # the 100 reaches the top row
    check rows[^1].startsWith("*")           # the 0 reaches the bottom one

  test "the step between two values is drawn, so the trace is connected":
    let rows = lineChart(@[0.0, 100.0], 2, 4, 0.0, 100.0, pgAscii)
    for r in rows: check r.endsWith("*")     # the riser fills the new column

  test "a fixed scale is honoured and out-of-range values are clamped":
    let rows = lineChart(@[-50.0, 150.0], 2, 3, 0.0, 100.0, pgAscii)
    check rows[0] == " *"
    check rows[^1].startsWith("*")

  test "a braille chart holds two values per column, a quadrant one likewise":
    check dotsX(pgBraille) == 2 and dotsY(pgBraille) == 4
    check dotsX(pgBlocks) == 2 and dotsY(pgBlocks) == 2
    check dotsX(pgAscii) == 1 and dotsY(pgAscii) == 1
    # Trailing window, as `sparkline`: the older half falls off a chart half as
    # wide as the data, and the visible end is the recent one.
    let values = @[0.0, 0.0, 0.0, 0.0, 9.0, 9.0]
    check lineChart(values, 2, 1, glyphs = pgAscii) == @["**"]
    check lineChart(values, 3, 1, glyphs = pgAscii)[0].endsWith("*")

  test "a one-row chart is the sparkline shape":
    let values = @[1.0, 5.0, 3.0, 9.0, 2.0, 7.0]
    for g in AllGlyphs:
      check lineSpark(values, 6, glyphs = g) == lineChart(values, 6, 1, glyphs = g)[0]
      check displayWidth(lineSpark(values, 6, glyphs = g)) == 6

suite "gradient widgets":
  test "a gradient gauge is exactly as wide as a plain one":
    for w in [1, 5, 20, 40]:
      for f in [0.0, 0.01, 0.25, 0.5, 0.73, 0.999, 1.0]:
        check displayWidth(gauge(f, w, HeatGradient)) == w
        check displayWidth(gauge(f, w, HeatGradient)) == displayWidth(gauge(f, w))

  test "a half-block gauge is exactly as wide as a solid one":
    # The bar is `▌` per cell with the next ramp point behind it, so the cell
    # count is unchanged and only the colour resolution doubles. A width check is
    # what catches the alternative — a caller reading `▌` as half a column.
    for w in [1, 5, 20, 40]:
      for f in [0.0, 0.01, 0.25, 0.5, 0.73, 0.999, 1.0]:
        checkpoint "w=" & $w & " f=" & $f
        check displayWidth(gauge(f, w, HeatGradient)) == w
        check displayWidth(gauge(f, w, HeatGradient)) ==
              displayWidth(gauge(f, w, HeatGradient, halfBlock = false))

  test "a half-block cell carries two ramp points, one in the background":
    let bar = gauge(1.0, 8, HeatGradient)
    check "▌" in bar
    check "38;2;" in bar              # a foreground
    check "48;2;" in bar              # and a background, which is the new half
    check "█" notin bar
    # Turned off, it is the old bar exactly: one colour per cell, no background.
    let solid = gauge(1.0, 8, HeatGradient, halfBlock = false)
    check "█" in solid
    check "48;2;" notin solid

  test "half-block turns itself off when there is no colour to carry it":
    # Under `cpNoColor` `sgr` emits nothing, so a row of bare `▌` would draw a
    # bar half the width it means — worse than the colour the user asked to be
    # rid of. This is the one test here that touches the profile global, so it
    # puts it back.
    let saved = colorProfile()
    setColorProfile(cpNoColor)
    check gauge(0.62, 30, HeatGradient) ==
          gauge(0.62, 30, HeatGradient, halfBlock = false)
    check "▌▌" notin gauge(1.0, 30, HeatGradient)
    setColorProfile(saved)

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

  test "a coloured line chart matches the plain one cell for cell":
    let values = @[1.0, 4.0, 9.0, 3.0, 7.0, 2.0, 8.0]
    for g in [pgBraille, pgBlocks, pgAscii]:
      let
        plain = lineChart(values, 10, 3, glyphs = g)
        painted = lineChart(values, 10, 3, HeatGradient, glyphs = g)
      check painted.len == plain.len
      for i in 0 ..< plain.len:
        checkpoint $g & " row " & $i
        check painted[i].stripAnsi == plain[i]
        check displayWidth(painted[i]) == 10
      check lineSpark(values, 10, HeatGradient, glyphs = g).stripAnsi ==
            lineSpark(values, 10, glyphs = g)

  test "a coloured line chart colours a cell by how high the trace got in it":
    # The topmost dot, so the colour and the glyph say the same thing. A cell the
    # trace never entered is left unstyled rather than painted at the floor.
    let g = gradient(hex"#000000", hex"#ffffff")
    let rows = lineChart(@[0.0, 100.0], 2, 2, g, 0.0, 100.0, pgAscii)
    check "38;2;255;255;255" in rows[0]      # the top row is the far end of the ramp
    check "38;2;0;0;0" in rows[^1]
    check rows[0].stripAnsi == " *"

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

  test "the bar's own style survives a reset in a segment":
    # A coloured segment is the ordinary case here — a mode indicator, a dirty
    # marker. Its reset ends the bar's background too, so without `renderOver`
    # the bar stops at the first styled segment and the rest of the row is bare,
    # which the width checks above cannot see.
    let bg = Style().bg(ansiColor(4))
    let bar = statusBar(Style().bold().render("NORMAL"), "", "12:04", 40, bg)
    check (Reset & bg.sgr()) in bar
    check displayWidth(bar) == 40
