import std/[unittest, strutils]
import nimtui/[ansi, layout]

## Blocks are plain strings, so the arithmetic that has to hold is about columns:
## a block is a rectangle only if every line measures the same, and every helper
## has to keep that true for styled and double-width text.

suite "layout":
  test "padBlock produces an exact rectangle":
    let b = padBlock("a\nbb\nccc", 5, 4)
    check b.split('\n').len == 4
    for line in b.split('\n'):
      check displayWidth(line) == 5

  test "joinHorizontal pads the shorter block":
    let joined = joinHorizontal(["a\nb\nc", "x"], gap = 1)
    check joined.split('\n') == @["a x", "b  ", "c  "]

  test "renderBox has the requested dimensions":
    for w in [10, 20, 40]:
      for h in [3, 5, 12]:
        let b = renderBox("content\nlines", w, h, title = "t")
        check blockHeight(b) == h
        for line in b.split('\n'):
          check displayWidth(line) == w

  test "renderBox at heights too small to hold a body":
    # Two border rows are the floor, so a height of 2 is exactly the borders and
    # nothing else. This used to come back as three rows for any height up to
    # three: `padBlock(content, inner, 0)` returns "", and `"".split('\n')` is
    # `@[""]`, so an empty body smuggled in a blank line.
    check blockHeight(renderBox("body", 8, 2)) == 2
    check blockHeight(renderBox("body", 8, 3)) == 3
    for h in [0, 1]:
      check blockHeight(renderBox("body", 8, h)) == 2

  test "renderBox stays rectangular at widths too small for an interior":
    # The top row used to carry a horizontal unconditionally, so with no interior
    # to put it in it came out one column wider than every other row.
    for w in 0 .. 6:
      let want = max(w, 2)          # two border columns are the floor
      for title in ["", "t", "a title far too long for this"]:
        for line in renderBox("body", w, 3, title = title,
                              borderStyle = Style().faint()).split('\n'):
          check displayWidth(line) == want

  test "padBlock leaves an already exact block untouched":
    # What lets the helpers skip most of their work: a block that is already
    # rectangular is passed through, so composing them does not re-pad.
    let exact = padBlock("a\nbb\nccc", 5, 4)
    check padBlock(exact, 5, 4) == exact
    check joinHorizontal([exact]) == exact

  test "padBlockLines is padBlock without the join":
    for w in [-1, 0, 1, 3, 6]:
      for h in [-1, 0, 1, 2, 4]:
        check padBlockLines("a\nbb\nccc", w, h).join("\n") ==
              padBlock("a\nbb\nccc", w, h)

  test "renderBox survives a title longer than the box":
    let b = renderBox("x", 12, 3, title = "an extremely long title")
    check blockWidth(b) == 12

  test "renderBox aligns with double-width content and titles":
    for w in [12, 20, 33]:
      let b = renderBox("日本語のテキスト\nmixed a日b本c", w, 5, title = "ファイル")
      for line in b.split('\n'):
        check displayWidth(line) == w

  test "joinHorizontal aligns columns of double-width text":
    check joinHorizontal(["日本\n語", "abc\nd"], gap = 1).split('\n') ==
      @["日本 abc", "語   d  "]

  test "elide is exact when the cut lands inside a wide rune":
    for w in 1 .. 20:
      check displayWidth(elide("日本語のテキストです", w)) == min(w, 20)

  test "elide marks a truncated string":
    check elide("hello", 10) == "hello"
    check elide("hello world", 8) == "hello w…"
    check displayWidth(elide("hello world", 8)) == 8

  test "centerVisible centres and never overflows":
    check centerVisible("ab", 6) == "  ab  "
    check displayWidth(centerVisible("abcdef", 4)) == 4

const
  RuledBorders = [RoundedBorder, SquareBorder, DoubleBorder, ThickBorder,
                  DashedBorder, AsciiBorder, HiddenBorder, BlockBorder]
    ## The borders a table can draw an interior rule through.
  AllBorders = [RoundedBorder, SquareBorder, DoubleBorder, ThickBorder,
                DashedBorder, AsciiBorder, HiddenBorder, BlockBorder,
                OuterHalfBlockBorder, InnerHalfBlockBorder]

suite "borders":
  test "every built-in border renders an exact box":
    for b in AllBorders:
      for w in [4, 12, 30]:
        let box = renderBox("body", w, 5, title = "t", border = b)
        check blockHeight(box) == 5
        for line in box.split('\n'):
          check displayWidth(line) == w

  test "the junction pieces are filled in on every ruled built-in":
    # A table draws rules through the frame, and falls back to `horizontal`
    # where a junction is missing — correct for a hand-written border, but the
    # built-ins should not be relying on it.
    #
    # The two half-block borders are the deliberate exception and are not in
    # this list: there is no glyph for a thin rule meeting a half-block edge, so
    # the fallback *is* the answer for them rather than an omission.
    for b in RuledBorders:
      for piece in [b.teeDown, b.teeUp, b.teeRight, b.teeLeft, b.cross]:
        check piece.len > 0
        check displayWidth(piece) == 1

  test "every edge is one column, whichever way it is reached":
    # A two-column border glyph wraps the frame, which desynchronises every line
    # below it rather than just that one.
    for b in AllBorders:
      for edge in [b.topEdge, b.bottomEdge, b.leftEdge, b.rightEdge]:
        check displayWidth(edge) == 1

  test "the four edges fall back to horizontal and vertical":
    # Which is what keeps every border written before those fields existed —
    # including hand-written ones — drawing all four of its sides.
    let plain = Border(topLeft: "+", topRight: "+", bottomLeft: "+",
                       bottomRight: "+", horizontal: "-", vertical: "|")
    check plain.topEdge == "-"
    check plain.bottomEdge == "-"
    check plain.leftEdge == "|"
    check plain.rightEdge == "|"
    check renderBox("x", 12, 3, border = plain).split('\n')[0] == "+----------+"
    for b in RuledBorders:
      check b.topEdge == b.bottomEdge      # the ruled borders are symmetric
      check b.leftEdge == b.rightEdge

  test "a half-block border differs on opposite edges":
    # The reason the four fields exist at all: one `horizontal` and one
    # `vertical` cannot say `▀` above and `▄` below.
    for b in [OuterHalfBlockBorder, InnerHalfBlockBorder]:
      check b.topEdge != b.bottomEdge
      check b.leftEdge != b.rightEdge
    let box = renderBox("body", 10, 3, border = OuterHalfBlockBorder).split('\n')
    check box[0] == "▛▀▀▀▀▀▀▀▀▜"
    check box[1] == "▌body    ▐"
    check box[2] == "▙▄▄▄▄▄▄▄▄▟"

suite "panel":
  test "a panel renders the same box as renderBox":
    check panel().title("t").render("body", 20, 6) ==
          renderBox("body", 20, 6, title = "t")

  test "setters return copies, so a panel can be specialised":
    let base = panel().pad(1)
    let a = base.title("left")
    let b = base.title("right").border(ThickBorder)
    check base.titleText == ""
    check a.titleText == "left"
    check b.borderChars == ThickBorder
    check a.borderChars == RoundedBorder
    check b.padding == 1

  test "title alignment moves the label without changing the width":
    for align in [aLeft, aCenter, aRight]:
      let box = panel().title("title", align).render("x", 30, 4)
      for line in box.split('\n'):
        check displayWidth(line) == 30
    let left = panel().title("t", aLeft).render("x", 30, 3).split('\n')[0]
    let right = panel().title("t", aRight).render("x", 30, 3).split('\n')[0]
    check left != right
    check displayWidth(left) == displayWidth(right)

  test "a footer is let into the bottom border":
    let box = panel().title("top").footer("42 lines").render("x", 30, 4)
    let ls = box.split('\n')
    check "42 lines" in ls[^1]
    check "top" in ls[0]
    for line in ls:
      check displayWidth(line) == 30

  test "padding never eats into the frame":
    # An over-padded small panel must come back the size asked for rather than
    # overflowing it.
    for p in [0, 1, 2, 5, 20]:
      for w in [4, 9, 20]:
        for h in [2, 5, 9]:
          let box = panel().pad(p).render("body\ntext", w, h)
          check blockHeight(box) == h
          for line in box.split('\n'):
            check displayWidth(line) == w

  test "a fill styles the interior without changing the geometry":
    let box = panel().styled(fill = Style().bg(rgb(20, 20, 40)))
                     .render("body", 20, 5)
    check "48;2;20;20;40" in box
    for line in box.split('\n'):
      check displayWidth(line) == 20

  test "a fill survives a reset in the body it fills behind":
    # The body is pre-styled, which is the normal case — a panel wraps content
    # the caller has already coloured. `Style.render` closes with a reset, so
    # without `renderOver` the fill ends at the body's own reset and every pad
    # column after it comes out bare: the geometry above still passes, and the
    # panel is visibly half-filled. Same failure class as 9458a8b, one level up.
    let fill = Style().bg(rgb(0, 0, 180))
    let box = panel().styled(fill = fill).render(Style().fg(hex"#ffffff").render("hi"),
                                                 14, 3)
    check (Reset & fill.sgr()) in box
    for line in box.split('\n'):
      check displayWidth(line) == 14

  test "fillBlock survives a reset in its content too":
    let fill = Style().bg(rgb(0, 0, 180))
    let b = fillBlock(Style().fg(hex"#ffffff").render("hi"), fill, 10, 2)
    check (Reset & fill.sgr()) in b
    for line in b.split('\n'):
      check displayWidth(line) == 10

  test "a pre-styled title keeps its style to the end of the label":
    # A highlight inside a title ends `titleStyle` for the rest of it, the space
    # that pads it off the border included.
    let ts = Style().bold().fg(rgb(255, 200, 0))
    let box = panel().title("a" & Style().reverse().render("b") & "c")
                     .styled(title = ts).render("body", 20, 3)
    check (Reset & ts.sgr()) in box
    for line in box.split('\n'):
      check displayWidth(line) == 20

  test "a shadow grows the block by exactly one column and row":
    let plain = panel().render("body", 20, 6)
    let shadowed = panel().shadow().render("body", 20, 6)
    check blockWidth(shadowed) == blockWidth(plain) + 1
    check blockHeight(shadowed) == blockHeight(plain) + 1
    for line in shadowed.split('\n'):
      check displayWidth(line) == 21

suite "wrapping":
  test "no wrapped line exceeds the width":
    let text = "the quick brown fox jumps over the lazy dog " &
               "and then keeps on going for a while longer"
    for w in [5, 8, 12, 20, 40, 200]:
      for line in wrapText(text, w):
        check displayWidth(line) <= w

  test "words are kept whole when they fit":
    check wrapText("aaa bbb ccc", 7) == @["aaa bbb", "ccc"]

  test "a word longer than the line is broken rather than overflowing":
    let pieces = wrapText("supercalifragilistic", 7)
    for line in pieces:
      check displayWidth(line) <= 7
    check pieces.join("") == "supercalifragilistic"

  test "leading indentation survives":
    # `curW > 0` conflates "start of an output line" with "nothing added yet",
    # and using it to decide whether a separator space is owed dropped every
    # leading space — mangling indented code and quoted text even when the line
    # was short enough to need no wrapping at all.
    check wrapText("    indented", 40) == @["    indented"]
    check wrapText("  if x:\n    doThing()", 40) == @["  if x:", "    doThing()"]
    check wrapText("\ttabbed", 40) == @["\ttabbed"]

  test "interior runs of spaces survive too":
    check wrapText("a  b", 10) == @["a  b"]
    check wrapText("a   b", 10) == @["a   b"]

  test "a line that fits is returned unchanged":
    # The strongest form of the above: wrapping must be a no-op below the width.
    for line in ["plain", "    indented", "a  b", "日本語 テキスト", ""]:
      check wrapText(line, 40) == @[line]

  test "a continuation line does not inherit the separator space":
    check wrapText("aaa bbb", 3) == @["aaa", "bbb"]

  test "hard breaks and blank lines survive":
    check wrapText("a\n\nb", 10) == @["a", "", "b"]
    check wrapText("", 10) == @[""]

  test "double-width text wraps by columns, not runes":
    for w in [4, 6, 9, 14]:
      for line in wrapText("日本語 の テキスト です", w):
        check displayWidth(line) <= w

  test "a non-positive width yields nothing rather than looping":
    check wrapText("anything", 0).len == 0
    check wrapText("anything", -5).len == 0

suite "compositing":
  test "fillBlock squares the block and styles every line":
    let b = fillBlock("a\nbbb", Style().bg(rgb(10, 10, 10)))
    check blockWidth(b) == 3
    for line in b.split('\n'):
      check displayWidth(line) == 3

  test "overlay keeps the base's dimensions":
    let base = padBlock("....................\n".repeat(6), 20, 6)
    for x in [-5, 0, 3, 15, 25]:
      for y in [-2, 0, 2, 10]:
        let composed = overlay(base, "XXXX\nYYYY", x, y)
        check blockHeight(composed) == 6
        for line in composed.split('\n'):
          check displayWidth(line) == 20

  test "overlay puts the content where it says":
    let base = padBlock("....................", 20, 1)
    check overlay(base, "XX", 8, 0).stripAnsi == "........XX.........."

  test "a negative x clips the overlay rather than shifting it":
    let base = padBlock("....................", 20, 1)
    check overlay(base, "ABCD", -2, 0).stripAnsi == "CD.................."

  test "overlay does not lose the base's styling on either side":
    let base = Style().fg(rgb(0, 255, 0)).render(".".repeat(20))
    let composed = overlay(base, "XX", 8, 0)
    check composed.stripAnsi == "........XX.........."
    check displayWidth(composed) == 20
    # The tail is restyled from the escapes carried forward by `sliceVisible`,
    # so the green survives the splice.
    check composed.count("38;2;0;255;0") >= 2

  test "place centres a block inside another":
    let base = padBlock((".".repeat(21) & "\n").repeat(7), 21, 7)
    let composed = place(base, padBlock("###\n###\n###", 3, 3))
    check blockHeight(composed) == 7
    for line in composed.split('\n'):
      check displayWidth(line) == 21
    check composed.split('\n')[3].stripAnsi == ".........###........."

  test "each corner and edge is reachable, and says which it is":
    # The reason `VAlign` exists: this used to read `place(base, top, aLeft,
    # aRight)` for "bottom left", with the vertical member borrowed off the
    # horizontal enum. Every combination is asserted because the two axes are now
    # different types, and a transposed pair no longer compiles rather than
    # silently placing the block somewhere else.
    let base = padBlock((".".repeat(9) & "\n").repeat(5), 9, 5)
    let top = "##"
    proc at(h: Align, v: VAlign): tuple[row, col: int] =
      let lines = place(base, top, h, v).split('\n')
      for i, line in lines:
        let col = line.stripAnsi.find("##")
        if col >= 0: return (i, col)
      (-1, -1)

    check at(aLeft, vaTop) == (0, 0)
    check at(aCenter, vaTop) == (0, 3)
    check at(aRight, vaTop) == (0, 7)
    check at(aLeft, vaMiddle) == (2, 0)
    check at(aCenter, vaMiddle) == (2, 3)
    check at(aRight, vaMiddle) == (2, 7)
    check at(aLeft, vaBottom) == (4, 0)
    check at(aCenter, vaBottom) == (4, 3)
    check at(aRight, vaBottom) == (4, 7)

  test "the default is dead centre on both axes":
    let base = padBlock((".".repeat(9) & "\n").repeat(5), 9, 5)
    check place(base, "##") == place(base, "##", aCenter, vaMiddle)

  test "an alignment never moves the block outside the base":
    # Both extremes clamp at zero rather than going negative, which `overlay`
    # would take as an offset into the line.
    let base = padBlock("...\n...", 3, 2)
    for h in Align:
      for v in VAlign:
        let composed = place(base, "#####\n#####\n#####", h, v)
        checkpoint $h & " " & $v
        check blockHeight(composed) == 2
        for line in composed.split('\n'):
          check displayWidth(line) == 3

  test "an oversized overlay is clipped, not allowed to grow the base":
    let base = padBlock(".....\n.....\n.....", 5, 3)
    let composed = overlay(base, "#".repeat(40) & "\n" & "#".repeat(40), 0, 0)
    check blockHeight(composed) == 3
    for line in composed.split('\n'):
      check displayWidth(line) == 5

suite "alignment":
  test "alignVisible is exact in every direction":
    for align in [aLeft, aCenter, aRight]:
      for w in 1 .. 12:
        check displayWidth(alignVisible("abcde", w, align)) == w
        check displayWidth(alignVisible("日本語", w, align)) == w

suite "a border label is one line":
  ## A title or footer is let into a border row, so a line break in one makes the
  ## box a row taller than the height it was asked for — and a caller passing a
  ## filename, a position label or an error string has no reason to expect that
  ## the string has to be flat.

  test "a box with a newline in its title is still exactly as tall":
    for h in [3, 5, 12]:
      for w in [20, 40]:
        let b = renderBox("content", w, h, title = "one\ntwo")
        checkpoint $w & "x" & $h
        check blockHeight(b) == h
        for line in b.split('\n'):
          check displayWidth(line) == w

  test "and so is one with a newline in its footer":
    let b = renderBox("content", 30, 4, title = "t", footer = "1\n/\n9")
    check blockHeight(b) == 4
    for line in b.split('\n'):
      check displayWidth(line) == 30

  test "the label is still readable, flattened":
    check "one two" in renderBox("x", 30, 3, title = "one\ntwo").stripAnsi

  test "a Panel built the long way behaves the same":
    let p = panel().title("a\nb").footer("c\td")
    let b = p.render("body", 24, 5)
    check blockHeight(b) == 5
    for line in b.split('\n'):
      check displayWidth(line) == 24

suite "splitting a width":
  # The one property that matters, asserted everywhere below: the panes plus the
  # gaps come to exactly `total`. A row that is one column over does not misplace
  # one pane, it wraps and desynchronises the frame.

  proc exact(total: int, ratios: openArray[float], gap = 0): bool =
    ## The panes sum to `max(total - gaps, 0)` and none is negative. That is
    ## `total` minus the gaps exactly when the gaps fit; when they do not, every
    ## pane is zero and the row cannot be made to fit by any return value here,
    ## since the gaps are the caller's to draw.
    let w = splitWidths(total, ratios, gap)
    if w.len != ratios.len: return false
    var sum = 0
    for x in w:
      if x < 0: return false
      sum += x
    sum == max(total - gap * (max(w.len, 1) - 1), 0)

  test "the shares sum to the total, at every width":
    for total in 0 .. 200:
      checkpoint $total
      check exact(total, [1.0, 1.0])
      check exact(total, [1.0, 2.0, 1.0])
      check exact(total, [0.2, 0.3, 0.5])
      check exact(total, [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0])

  test "and with gaps between them":
    for total in 0 .. 200:
      checkpoint $total
      check exact(total, [1.0, 1.0], gap = 1)
      check exact(total, [1.0, 2.0, 1.0], gap = 2)
      check exact(total, [1.0, 1.0, 1.0, 1.0], gap = 3)

  test "an even split is even where it divides":
    check splitWidths(80, [1.0, 2.0, 1.0]) == @[20, 40, 20]
    check splitWidths(60, 3) == @[20, 20, 20]
    check splitWidths(100, [0.25, 0.75]) == @[25, 75]

  test "weights are normalised, so they need not sum to one":
    check splitWidths(80, [1.0, 2.0, 1.0]) == splitWidths(80, [0.25, 0.5, 0.25])
    check splitWidths(90, [3.0, 6.0]) == splitWidths(90, [1.0, 2.0])

  test "the remainder goes where the rounding was closest":
    # 100/3 is 33.33 each: two panes get 33 and one gets 34, not 33/33/34 by
    # position and never 33/33/33 with a column dropped.
    check splitWidths(100, 3) == @[34, 33, 33]
    check splitWidths(10, [1.0, 1.0, 1.0, 1.0]) == @[3, 3, 2, 2]

  test "no pane is more than a column from its exact share":
    for total in 1 .. 200:
      let ratios = [1.0, 3.0, 5.0, 7.0]
      var sum = 0.0
      for r in ratios: sum += r
      let w = splitWidths(total, ratios)
      for i, r in ratios:
        checkpoint $(total, i)
        check abs(w[i].float - r / sum * total.float) < 1.0

  test "the answer is a function of the arguments alone":
    # A layout that twitched between frames would mean the tie-break depended on
    # something other than the input.
    for i in 0 .. 20:
      check splitWidths(100, 7) == splitWidths(100, 7)
      check splitWidths(37, [1.0, 1.0, 1.0]) == splitWidths(37, [1.0, 1.0, 1.0])

  test "the degenerate cases are widths, not errors":
    check splitWidths(80, newSeq[float]()).len == 0
    check splitWidths(80, 0).len == 0
    check splitWidths(0, 3) == @[0, 0, 0]
    check splitWidths(-10, 3) == @[0, 0, 0]
    check splitWidths(1, [1.0, 1.0, 1.0]) == @[1, 0, 0]
    # Gaps alone eating the width leaves panes of zero, never negative ones —
    # here exactly, and below where they do not even fit.
    check splitWidths(4, 3, gap = 2) == @[0, 0, 0]
    check splitWidths(2, 4, gap = 3) == @[0, 0, 0, 0]

  test "a negative weight counts as zero rather than stealing width":
    check splitWidths(80, [-1.0, 1.0, 1.0]) == @[0, 40, 40]

  test "no weight at all is an even split, not nothing":
    check splitWidths(90, [0.0, 0.0, 0.0]) == @[30, 30, 30]
    check exact(100, [0.0, 0.0, 0.0])

  test "the shares actually fit joinHorizontal":
    # The two agreeing about `gap` is the point of it being a parameter here,
    # and this is the assertion that would catch them drifting apart.
    for total in [20, 37, 80, 120]:
      for gap in 0 .. 2:
        let w = splitWidths(total, 3, gap)
        let row = joinHorizontal([padBlock("a", w[0], 1), padBlock("b", w[1], 1),
                                  padBlock("c", w[2], 1)], gap)
        checkpoint $(total, gap)
        check displayWidth(row) == total
