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
