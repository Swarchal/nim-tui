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

suite "borders":
  test "every built-in border renders an exact box":
    for b in [RoundedBorder, SquareBorder, DoubleBorder, ThickBorder,
              DashedBorder, AsciiBorder, HiddenBorder]:
      for w in [4, 12, 30]:
        let box = renderBox("body", w, 5, title = "t", border = b)
        check blockHeight(box) == 5
        for line in box.split('\n'):
          check displayWidth(line) == w

  test "the junction pieces are filled in on every built-in":
    # A table draws rules through the frame, and falls back to `horizontal`
    # where a junction is missing — correct for a hand-written border, but the
    # built-ins should not be relying on it.
    for b in [RoundedBorder, SquareBorder, DoubleBorder, ThickBorder,
              DashedBorder, AsciiBorder, HiddenBorder]:
      for piece in [b.teeDown, b.teeUp, b.teeRight, b.teeLeft, b.cross]:
        check piece.len > 0
        check displayWidth(piece) == 1

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
