import std/[unittest, strutils, unicode]
import nimtui/[ansi, digits]

## Three rows of exactly the same width, whatever the argument. The tables are
## hand-drawn pictures, so the module's own `static:` block pins their shape;
## what is left for here is the block builder around them and the characters
## that are *not* in the tables.

suite "numerals three rows tall":
  test "a block is three rows of the width the arithmetic says":
    for gap in 0 .. 3:
      for s in ["", "0", "12:34", "0.5", "ABCDEF", "  ", "-1,234.56"]:
        checkpoint "gap=" & $gap & " " & escape(s)
        let rows = bigDigits(s, gap = gap).split('\n')
        check rows.len == 3
        let want = if s.len == 0: 0
                   else: s.runeLen * DigitWidth + (s.runeLen - 1) * gap
        for r in rows:
          check displayWidth(r) == want

  test "the bold set is the same size as the thin one":
    # They are the same shapes at two weights, so a caller can switch between
    # them without relaying out the panel around them.
    for s in ["0123456789", "12:34", "-+=/x"]:
      check displayWidth(bigDigits(s).split('\n')[0]) ==
            displayWidth(bigDigits(s, bold = true).split('\n')[0])

  test "an unknown character is three blank columns, not a hole":
    # Same reasoning as `boxChar`'s degradation: whatever comes back has to be
    # exactly as wide as what was asked for, because the alternative is a block
    # whose three lines are different lengths.
    for s in ["z", "?", "€", "日", ""]:
      checkpoint escape(s)
      let rows = bigDigits(s).split('\n')
      for r in rows:
        check r == "   "

  test "a newline cannot turn one block into two":
    # The flattening problem the rest of the library solves with `oneLine`,
    # solved here by construction: a newline is simply not in the table.
    let rows = bigDigits("1\n2").split('\n')
    check rows.len == 3
    for r in rows:
      check displayWidth(r) == 3 * DigitWidth + 2

  test "a wide rune counts as one character, not as its bytes":
    # Iterating bytes would draw four blanks for one CJK rune and the width
    # arithmetic above would then be wrong by nine columns.
    check bigDigits("日").split('\n')[0] == "   "
    check bigDigits("日本").split('\n')[0] == "       "

  test "hex folds case, and nothing else does":
    check digitGlyph("a".runeAt(0)) == digitGlyph("A".runeAt(0))
    check digitGlyph("f".runeAt(0)) == digitGlyph("F".runeAt(0))
    check digitGlyph("X".runeAt(0)) == digitGlyph("x".runeAt(0))
    # `g` is not hex and `Z` is not anything: a near miss is left blank rather
    # than guessed at, since the set is small enough for a guess to be wrong.
    check digitGlyph("g".runeAt(0)) == ["   ", "   ", "   "]
    check digitGlyph("Z".runeAt(0)) == ["   ", "   ", "   "]

  test "every digit draws a different picture":
    # The failure a dimensional check cannot see: two entries transposed, or one
    # copied and not edited. `8` and `B` are the pair this actually catches —
    # the upper-case seven-segment `B` *is* an `8`, which is why the table uses
    # the lower-case shape.
    var seen: seq[array[3, string]]
    for c in "0123456789ABCDEF":
      let g = digitGlyph(Rune(ord(c)))
      checkpoint $c
      check g notin seen
      seen.add g

  test "the two weights differ everywhere a heavy glyph exists":
    # Four characters are deliberately identical in both sets, because Unicode
    # has no heavy diagonal and no second weight of dot. Everything else must
    # differ, or an entry was copied from the thin table and left alone.
    var same: seq[char]
    for c in DigitChars:
      if digitGlyph(Rune(ord(c))) == digitGlyph(Rune(ord(c)), bold = true):
        same.add c
    check same == @[' ', '.', ':', '/', 'x']

  test "the gap is between characters and not inside them":
    check bigDigits("11", gap = 0).split('\n')[1] == " │  │ "
    check bigDigits("11", gap = 1).split('\n')[1] == " │   │ "
    check bigDigits("11", gap = 3).split('\n')[1] == " │     │ "

  test "the sample in the doc comment is what it renders":
    check bigDigits("12:34") == " ╷  ╶─┐  ▪  ╶─┐ ╷ ╷\n" &
                                " │  ┌─┘     ╶─┤ └─┤\n" &
                                " ╵  └─╴  ▪  ╶─┘   ╵"
