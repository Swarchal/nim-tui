import std/[unittest, unicode]
import nimtui/ansi

const
  red = "\e[31m"
  reset = "\e[0m"

suite "escapeLen":
  test "recognises CSI sequences":
    check escapeLen("\e[31m", 0) == 5
    check escapeLen("\e[1;5A", 0) == 6
    check escapeLen("\e[0m", 0) == 4

  test "recognises OSC sequences with both terminators":
    check escapeLen("\e]0;title\a", 0) == 10
    check escapeLen("\e]0;title\e\\", 0) == 11

  test "handles two-byte and unterminated sequences":
    check escapeLen("\eM", 0) == 2
    check escapeLen("\e", 0) == 1
    check escapeLen("\e[1;5", 0) == 5      # still makes progress

  test "returns 0 for plain text":
    check escapeLen("hello", 0) == 0
    check escapeLen(red & "x", 5) == 0

suite "stripAnsi and displayWidth":
  test "strips styling":
    check stripAnsi(red & "hello" & reset) == "hello"
    check stripAnsi("a\e[1mb\e[0mc") == "abc"

  test "width ignores escapes":
    check displayWidth(red & "hello" & reset) == 5
    check displayWidth("") == 0

  test "width counts columns, not runes or bytes":
    check displayWidth("héllo") == 5
    check "héllo".len == 6
    check displayWidth("日本") == 4       # two runes, four columns
    check "日本".len == 6                 # six bytes

suite "runeWidth":
  test "ordinary text is one column":
    for s in ["a", "Z", "0", " ", "é", "Ω", "ж"]:
      check runeWidth(s.runeAt(0)) == 1

  test "East Asian wide and fullwidth are two columns":
    for s in ["日", "本", "한", "あ", "漢", "："]:   # last is FULLWIDTH COLON
      check runeWidth(s.runeAt(0)) == 2

  test "emoji with emoji presentation are two columns":
    for s in ["🎉", "🚀", "⌚", "✅", "🀄"]:
      check runeWidth(s.runeAt(0)) == 2

  test "emoji with text presentation stay one column":
    # U+2764 and friends are drawn as text unless followed by VS16, which this
    # does not track — see the limitations in width.nim.
    for s in ["❤", "⚠", "▶", "✔"]:
      check runeWidth(s.runeAt(0)) == 1

  test "combining marks and zero-width characters are no columns":
    check runeWidth(Rune(0x0301)) == 0        # combining acute
    check runeWidth(Rune(0x200B)) == 0        # zero-width space
    check runeWidth(Rune(0x200D)) == 0        # zero-width joiner
    check runeWidth(Rune(0xFE0F)) == 0        # variation selector-16
    check runeWidth(Rune(0x11A0)) == 0        # Hangul Jamo medial vowel

  test "control characters are no columns, never negative":
    check runeWidth(Rune(0x00)) == 0
    check runeWidth(Rune(0x1B)) == 0
    check runeWidth(Rune(0x7F)) == 0

  test "East Asian ambiguous stays one column":
    # Box drawing, block elements, braille and the ellipsis are all Ambiguous.
    # Measuring them as wide would break every bordered panel in examples/lib.
    for s in ["─", "│", "╭", "█", "▁", "┃", "…", "⠋", "·", "✓"]:
      check runeWidth(s.runeAt(0)) == 1

  test "a base with combining marks measures as its base":
    check displayWidth("é") == 1
    check displayWidth("à́̂") == 1

  test "range boundaries are inclusive on both ends":
    # Off-by-one in a table entry is the likely transcription error, so check
    # the rune either side of a few boundaries as well as the boundary itself.
    check runeWidth(Rune(0x02FF)) == 1        # just before combining marks
    check runeWidth(Rune(0x0300)) == 0
    check runeWidth(Rune(0x036F)) == 0
    check runeWidth(Rune(0x0370)) == 1        # just after
    check runeWidth(Rune(0x4DFF)) == 1        # just before CJK Unified
    check runeWidth(Rune(0x4E00)) == 2
    check runeWidth(Rune(0x9FFF)) == 2
    check runeWidth(Rune(0xFF00)) == 1        # just before fullwidth forms
    check runeWidth(Rune(0xFF01)) == 2
    check runeWidth(Rune(0xFF60)) == 2
    check runeWidth(Rune(0xFF61)) == 1        # halfwidth forms begin

  test "displayWidth is the sum of its runes":
    for s in ["", "abc", "日本語", "a日b本c", "héllo", "🎉ok"]:
      var total = 0
      for r in s.runes: total += runeWidth(r)
      check displayWidth(s) == total

suite "truncateVisible":
  test "cuts to visible width":
    check truncateVisible("hello world", 5) == "hello"
    check truncateVisible("hello", 10) == "hello"
    check truncateVisible("hello", 0) == ""

  test "keeps escapes past the cut so styling closes":
    let styled = red & "hello world" & reset
    let cut = truncateVisible(styled, 5)
    check stripAnsi(cut) == "hello"
    check cut == red & "hello" & reset

  test "does not split multi-byte runes":
    check truncateVisible("héllo", 2) == "hé"

  test "cuts on columns, not runes":
    check truncateVisible("日本語", 4) == "日本"
    check truncateVisible("日本語", 6) == "日本語"

  test "a wide rune straddling the cut becomes a space":
    # Otherwise the result would be one column short and everything to its
    # right would shift left by a cell.
    check truncateVisible("日本語", 3) == "日 "
    check truncateVisible("a日", 2) == "a "

  test "stays exactly `width` columns whenever the input is long enough":
    for s in ["hello world", "日本語のテキスト", "a日b本c語d", "🎉🎉🎉🎉"]:
      for w in 1 .. displayWidth(s):
        check displayWidth(truncateVisible(s, w)) == w

  test "combining marks follow their base across the cut":
    let decomposed = "abé"                # "abé", with a combining acute
    check displayWidth(decomposed) == 3
    # The mark is kept when its base is kept...
    check truncateVisible(decomposed, 3) == decomposed
    # ...and dropped with it, rather than reattaching to the "b".
    check truncateVisible(decomposed, 2) == "ab"

suite "padVisible":
  test "pads to width ignoring escapes":
    check padVisible("ab", 5) == "ab   "
    check padVisible(red & "ab" & reset, 4) == red & "ab" & reset & "  "

  test "never truncates":
    check padVisible("abcdef", 3) == "abcdef"
