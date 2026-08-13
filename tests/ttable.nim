import std/[unittest, strutils, sequtils]
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

  test "a borderless table's header rule is as wide as its rows":
    # The case this suite used to miss twice over: it turned the rule *off* and
    # it passed a width, and a width clips the offending line back into
    # agreement. Unconstrained and with the rule on, the rule used to come out
    # `columns + 1` wider than every row — a `┼` at every column boundary that
    # has no separator to cross, plus a glyph off each end where there is no
    # frame. Nothing pads a block to its narrowest line, so the whole table then
    # lays out at the rule's width.
    var t = sample()
    t.showBorder = false
    for padding in [0, 1, 2]:
      t.padding = padding
      let ls = t.lines()
      checkpoint "padding " & $padding
      check ls.len == 5                        # header, rule, three rows
      for line in ls:
        check displayWidth(line) == t.totalWidth
      check "┼" notin ls[1]                    # nothing to cross

  test "a borderless table is exactly its rows, with no frame column":
    # And the width is the columns and their padding, nothing else: a frame that
    # is not drawn must not still be paid for.
    var t = table([column("a", width = 4), column("b", width = 6)])
    t.add("x", "y")
    t.showBorder = false
    t.padding = 1
    check t.totalWidth == 4 + 6 + 4
    for line in t.lines(): check displayWidth(line) == 14

  test "hiding the header drops exactly one row":
    var t = sample()
    let withHeader = t.lines().len
    t.showHeader = false
    t.headerRule = false
    check t.lines().len == withHeader - 2

  test "every built-in border keeps the geometry":
    for b in [RoundedBorder, SquareBorder, DoubleBorder, ThickBorder,
              DashedBorder, AsciiBorder, HiddenBorder, BlockBorder,
              OuterHalfBlockBorder, InnerHalfBlockBorder]:
      var t = sample()
      t.borderChars = b
      for line in t.lines(40):
        check displayWidth(line) == 40

  test "a border with different sides puts each one where it belongs":
    # The half-block borders have no junction glyphs, so this is also the test
    # that a table falls back to the edge it is drawing rather than dropping the
    # rule — and that the left frame, the column separators and the right frame
    # are three different glyphs rather than one repeated.
    var t = sample()
    t.borderChars = OuterHalfBlockBorder
    var lines: seq[string]
    for line in t.lines(40): lines.add stripAnsi(line)   # the border is styled
    check lines[0].startsWith("▛")
    check lines[0].endsWith("▜")
    check "▀" in lines[0]
    check lines[^1].startsWith("▙")
    check lines[^1].endsWith("▟")
    check "▄" in lines[^1]
    for line in lines[1 ..< lines.high]:
      if line.startsWith("▌"): check line.endsWith("▐")

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

  test "a striped row keeps its background across a cell the caller coloured":
    # A per-cell colour has to be baked into the cell text — the table styles
    # columns and rows, not cells — so a striped row carries a reset in the
    # middle of it. The stripe has to come back after it, or the row is painted
    # only as far as the coloured word and the rest of that cell is a hole.
    let bg = Style().bg(hex"#161b33")
    var t = table([column("level", width = 9), column("message")])
    t.zebra = bg
    t.add("INFO", "first")
    t.add(Style().fg(hex"#d29922").render("WARNING"), "second")
    let striped = t.render(40).split('\n')[4]
    check "WARNING" in striped.stripAnsi
    check (Reset & bg.sgr()) in striped     # re-armed after the cell's own reset
    check displayWidth(striped) == 40

  test "padding widens every column by the same amount":
    var t = sample()
    let base = t.totalWidth
    t.padding = 2
    check t.totalWidth == base + t.columns.len * 2
    for line in t.lines():
      check displayWidth(line) == t.totalWidth

suite "a cell that is not one line":
  ## The failure this prevents is not a wrong-looking table, it is a
  ## desynchronised frame: `displayWidth` counts a newline as no columns, so the
  ## table reports the height the layout believed while the terminal draws one
  ## line more, and every line below it lands a row late. Log messages and
  ## exception text are the ordinary contents of a table cell, and neither is
  ## under the caller's control.

  proc withMessages(msg: string): Table =
    result = table([column("level"), column("message"), column("age")])
    result.add("INFO", "started", "1s")
    result.add("ERROR", msg, "2s")
    result.add("INFO", "carried on", "3s")

  const trace = "boom: connection refused\n  at dial()\n\tat main()"

  test "the table is exactly as tall as its rows, whatever is in them":
    let flat = withMessages("boom")
    let multi = withMessages(trace)
    for w in [0, 80, 60, 40, 24, 12]:
      checkpoint "width " & $w
      check multi.lines(w).len == flat.lines(w).len

  test "and every line is still exactly the width asked for":
    let t = withMessages(trace)
    for w in [80, 60, 40, 30, 24, 16, 8]:
      for line in t.lines(w):
        checkpoint "width " & $w & ": " & line
        check displayWidth(line) == w

  test "the message is still there, on one line, with spaces for the breaks":
    let rendered = withMessages(trace).render(80)
    check '\n' in rendered                    # the row separators, and only those
    let row = rendered.split('\n').filterIt("boom" in it)[0]
    check "at main()" in row                  # all three fragments on one line
    check "at dial()" in row

  test "a header with a newline in it does not add a line either":
    # Rarer than a cell, and reached the same way: `header` is a public field.
    var t = sample()
    let before = t.lines(60).len
    t.columns[0].header = "ser\nvice"
    check t.lines(60).len == before
    for line in t.lines(60):
      check displayWidth(line) == 60

  test "a cell written straight into `rows` is flattened too":
    # `add` is not the only way in — reusing a table across frames by assigning
    # `rows` is cheaper and documented, so the guarantee cannot live in `add`.
    var t = sample()
    t.rows[0][0] = "api\nv2"
    check t.lines(50).len == sample().lines(50).len
    for line in t.lines(50):
      check displayWidth(line) == 50

  test "the natural width accounts for the flattened cell, not the raw one":
    # `columnWidths` sizes a flexible column from its content, so it has to
    # measure the same string `render` draws. Unflattened, "a\nb" is two columns
    # and the column comes out one narrower than the three it ends up drawing —
    # which is why the flattening lives in the accessor both of them go through.
    var narrow = table([column("c")])
    narrow.add("a\nb")
    check narrow.columnWidths() == @[3]
    for line in narrow.render().split('\n'):
      check displayWidth(line) == narrow.totalWidth

suite "a frame heavier than what it divides":
  ## `ruledBorder(frame, rules)` is the only way to get a border whose interior
  ## rules are a different weight from its frame, and a table is the only place
  ## those rules are drawn — so this is where the sixteen weight pairings have to
  ## be exercised, not in `tlayout.nim` where there is no interior to rule.

  test "every pairing renders a table exactly as wide as asked":
    for frame in LineWeight:
      for rules in LineWeight:
        checkpoint $frame & " frame, " & $rules & " rules"
        var t = sample()
        t.borderChars = ruledBorder(frame, rules)
        for total in [20, 44, 80]:
          for line in t.lines(total):
            check displayWidth(line) == total

  test "the separators are the rule weight and the frame is not":
    # The point of the whole exercise. Drawn by hand this is where it goes
    # wrong: the column separator and the left edge are different glyphs on a
    # mixed border and the same glyph on every other one, so a call site that
    # reaches for `vertical` looks correct until someone builds one of these.
    var t = sample()
    t.borderChars = ruledBorder(lwDouble, lwThin)
    t.borderStyle = Style()
    let rows = t.lines()
    for line in rows[1 .. ^2]:
      if "║" in line:
        check "│" in line          # a body row: frame outside, rule inside
    check rows[0].startsWith("╔")
    check "╤" in rows[0]           # the top edge meeting a thin separator
    check "╟" in rows[2] and "┼" in rows[2]   # the header rule crossing it
    check rows[^1].startsWith("╚") and "╧" in rows[^1]

  test "a uniform pairing is indistinguishable from the built-in":
    # `innerHorizontal` and `innerVertical` are left empty when the weights
    # match, so the accessors fall back and nothing about the output moves.
    var built = sample()
    built.borderChars = ruledBorder(lwDouble)
    var plain = sample()
    plain.borderChars = DoubleBorder
    check built.render(60) == plain.render(60)
