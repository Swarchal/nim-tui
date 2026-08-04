import std/[unittest, strutils]
import nimtui/[ansi, style, color, layout, table]

## Columns line up or they do not, and "do not" means every row after the wide
## one is shifted. So almost everything here is the same assertion at different
## sizes: every line of the block is exactly as wide as every other, with styled
## and double-width cells mixed in.

proc sample(): Table =
  result = table([column("service"),
                  column("reqs", align = aRight),
                  column("p99", align = aRight)])
  result.add("api", "1204", "82.4")
  result.add("worker", "318", "140.1")
  result.add("日本語サービス", "77", "9.9")

proc lines(t: Table, width = 0): seq[string] =
  t.render(width).split('\n')

suite "table geometry":
  test "an unconstrained table is rectangular at its natural width":
    let t = sample()
    for line in t.lines():
      check displayWidth(line) == t.totalWidth

  test "a requested width is hit exactly, wide or narrow":
    let t = sample()
    for w in [80, 60, 40, 30, 24, 20, 16, 12, 8, 4, 2]:
      for line in t.lines(w):
        check displayWidth(line) == w

  test "double-width cells do not shift the columns":
    var t = table([column("a"), column("b")])
    t.add("日本語", "x")
    t.add("ab", "yy")
    let ls = t.lines()
    check ls.len == 6                       # top, header, rule, 2 rows, bottom
    for line in ls:
      check displayWidth(line) == displayWidth(ls[0])

  test "styled cells measure as their visible width":
    var plain = table([column("a"), column("b")])
    plain.add("error", "1")
    var styled = table([column("a"), column("b")])
    styled.add(Style().fg(hex"#f85149").bold().render("error"), "1")
    check plain.totalWidth == styled.totalWidth
    for line in styled.lines():
      check displayWidth(line) == plain.totalWidth

  test "an empty table renders nothing rather than a stray frame":
    check table([]).render() == ""
    check table([]).totalWidth == 0

  test "a table with columns but no rows still draws its header":
    let t = table([column("a"), column("b")])
    let ls = t.lines()
    check ls.len == 4                       # top, header, rule, bottom
    for line in ls:
      check displayWidth(line) == t.totalWidth

suite "table sizing":
  test "fixed columns keep their width while flexible ones absorb the change":
    var t = table([column("fixed", width = 8), column("flex")])
    t.add("a", "b")
    check t.columnWidths(40)[0] == 8
    check t.columnWidths(60)[0] == 8
    check t.columnWidths(60)[1] > t.columnWidths(40)[1]

  test "shrinking respects minWidth before it gives up on it":
    var t = table([column("aaaaaaaaaa", minWidth = 6),
                   column("bbbbbbbbbb", minWidth = 4)])
    t.add("aaaaaaaaaa", "bbbbbbbbbb")
    # Chrome is 3 border cells plus 2 padding cells per column; give the content
    # exactly the two floors and neither column may go under.
    let w = t.columnWidths(6 + 4 + 3 + 2 * 2)
    check w[0] == 6
    check w[1] == 4

  test "minWidth is a shrink floor, never a minimum size":
    # A column of one-character values is naturally 1 wide. The default
    # minWidth of 3 must not widen it, nor licence shrinking it below its own
    # content in order to pay for a column that is genuinely too big.
    var t = table([column("aaaaaaaaaaaaaaaaaaaa"), column("b")])
    t.add("aaaaaaaaaaaaaaaaaaaa", "b")
    check t.columnWidths()[1] == 1
    # Only widths that force a shrink: given a total wider than the content, the
    # surplus is spread over the flexible columns and `b` legitimately grows.
    for total in [20, 14, 10]:
      check t.columnWidths(total)[1] == 1

  test "surplus is spread over the flexible columns, not dumped on one":
    var t = table([column("a"), column("b"), column("c")])
    t.add("x", "y", "z")
    let w = t.columnWidths(60)
    check max(w) - min(w) <= 1

  test "ragged rows are padded rather than rejected":
    var t = table([column("a"), column("b"), column("c")])
    t.add("only one")
    t.add("two", "cells")
    for line in t.lines():
      check displayWidth(line) == t.totalWidth

  test "over-long cells are elided, not overflowed":
    var t = table([column("a", width = 6)])
    t.add("abcdefghijkl")
    let body = t.lines()[3]
    check displayWidth(body) == t.totalWidth
    check "…" in body

suite "table appearance":
  test "borderless tables are still rectangular":
    var t = sample()
    t.showBorder = false
    t.headerRule = false
    for w in [50, 34, 20]:
      for line in t.lines(w):
        check displayWidth(line) == w

  test "hiding the header drops exactly one row":
    var t = sample()
    let withHeader = t.lines().len
    t.showHeader = false
    t.headerRule = false
    check t.lines().len == withHeader - 2

  test "every built-in border keeps the geometry":
    for b in [RoundedBorder, SquareBorder, DoubleBorder, ThickBorder,
              DashedBorder, AsciiBorder, HiddenBorder]:
      var t = sample()
      t.borderChars = b
      for line in t.lines(40):
        check displayWidth(line) == 40

  test "zebra striping does not change any width":
    var t = sample()
    t.zebra = Style().bg(hex"#161b33")
    for line in t.lines(40):
      check displayWidth(line) == 40

  test "a row style overrides zebra but keeps the column's colour":
    # `merge` is what makes this work: the row supplies a background only, and
    # must not wipe out the foreground the column asked for.
    var t = table([column("a", style = Style().fg(hex"#58a6ff"))])
    t.add("x")
    t.rowStyles = @[Style().bg(hex"#161b33")]
    let body = t.render().split('\n')[3]
    check "88;166;255" in body              # the column's foreground survived
    check "22;27;51" in body                # the row's background applied

  test "padding widens every column by the same amount":
    var t = sample()
    let base = t.totalWidth
    t.padding = 2
    check t.totalWidth == base + t.columns.len * 2
    for line in t.lines():
      check displayWidth(line) == t.totalWidth
