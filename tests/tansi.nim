import std/[unittest, unicode, strutils]
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

suite "sliceVisible":
  test "a slice from zero is a prefix":
    for w in 1 .. 10:
      check sliceVisible("abcdefgh", 0, w) == truncateVisible("abcdefgh", w)

  test "the window starts where it says":
    check sliceVisible("abcdefgh", 3, 3) == "def"
    check sliceVisible("abcdefgh", 6, 5) == "gh"     # runs out, like truncate
    check sliceVisible("abcdefgh", 20, 5) == ""

  test "a non-positive width or negative start yields nothing":
    check sliceVisible("abc", 0, 0) == ""
    check sliceVisible("abc", -1, 3) == ""

  test "the result is exactly the width asked for while the string lasts":
    let s = "日本語abcか"
    for start in 0 .. 8:
      for w in 1 .. 4:
        let piece = sliceVisible(s, start, w)
        if start + w <= displayWidth(s):
          check displayWidth(piece) == w

  test "a wide rune straddling either edge becomes a space":
    # Half a glyph cannot be drawn, so the cell is blanked and the width stays
    # exact rather than coming up one short.
    check sliceVisible("日本語", 0, 3) == "日 "
    check sliceVisible("日本語", 1, 4) == " 本 "
    # Columns 1 and 2 are the right half of 日 and the left half of 本, so
    # neither glyph can be drawn and both cells are blank. Two spaces is the
    # correct answer here, not " 本" — 本 needs two columns and only one is left.
    check sliceVisible("日本語", 1, 2) == "  "
    # A window landing on the boundary keeps the glyph whole.
    check sliceVisible("日本語", 2, 2) == "本"

  test "escapes before the window are carried to the front of the slice":
    # A window into the middle of a coloured run begins with no colour of its
    # own; dropping the escapes that preceded it renders the tail unstyled.
    let s = "\e[31mabcdef\e[0m"
    let piece = sliceVisible(s, 2, 2)
    check piece.stripAnsi == "cd"
    check piece.startsWith("\e[31m")
    check displayWidth(piece) == 2

  test "escapes inside and after the window are kept":
    let s = "ab\e[31mcd\e[0mef"
    check sliceVisible(s, 0, 6).stripAnsi == "abcdef"
    check sliceVisible(s, 0, 6).count("\e[") == 2

suite "oneLine":
  ## A control character measures zero columns and draws as an *action* — a line
  ## break, most of the time. `oneLine` is the boundary between text that came
  ## from somewhere else and a frame whose height the layout has already counted.

  test "the control characters that make a second line become spaces":
    # One space per control character, so `\r\n\t` is three of them.
    check oneLine("traceback:\n  line one\r\n\tline two") ==
          "traceback:   line one   line two"
    check '\n' notin oneLine("a\nb")
    check '\r' notin oneLine("a\rb")
    check '\t' notin oneLine("a\tb")
    check oneLine("\x0bvertical\x0ctab") == " vertical tab"

  test "text with nothing to flatten comes back unchanged":
    for s in ["", "plain ascii", "日本語", "with  spaces  ", "a-b_c/d.e"]:
      check oneLine(s) == s

  test "escape sequences survive intact":
    # ESC is itself a control character, so flattening bytes naively dismantles
    # every sequence in the string — and pre-styled text is the normal case, since
    # a per-cell colour has nowhere to live but the cell.
    let s = "\e[31mred\e[0m"
    check oneLine(s) == s
    check oneLine("\e[31mred\nline\e[0m") == "\e[31mred line\e[0m"
    # An OSC payload is punctuation all the way down and must not be touched either.
    check oneLine("\e]11;rgb:1e1e/1e1e/1e1e\e\\") == "\e]11;rgb:1e1e/1e1e/1e1e\e\\"

  test "C1 controls count, and arrive as ordinary UTF-8":
    # U+0085 is NEL: terminals that honour it break the line exactly as `\n`
    # does, and it reaches a log message as two perfectly valid UTF-8 bytes
    # rather than as a stray byte anything would flag.
    check oneLine("before\u0085after") == "before after"
    check "\u0085" notin oneLine("before\u0085after")

  test "multi-byte runes are not mistaken for control bytes":
    # Every continuation byte of a UTF-8 sequence is >= 0x80, and a naive byte
    # scan reads a good many of them as C1 controls.
    for s in ["é±°©", "日本語のログ", "→ ← ↑ ↓", "🙂"]:
      check oneLine(s) == s

  test "flattening widens, which is why it happens before measuring":
    # Not width-preserving, and nothing downstream may assume otherwise: a
    # control character is zero columns and the space replacing it is one. Every
    # helper that fits text to a width flattens on the way in for this reason.
    check displayWidth("a\nb") == 2
    check displayWidth(oneLine("a\nb")) == 3

  test "and it is the only thing that changes":
    for s in ["a\nb", "x\ty", "\e[31mq\nr\e[0m", "日\n本"]:
      check oneLine(s).len == s.len             # one byte in, one byte out
      check oneLine(oneLine(s)) == oneLine(s)   # idempotent
