## Numerals three rows tall, drawn from box-drawing glyphs.
##
## A clock, a countdown or a single headline figure read as a *display* rather
## than as text at this size, which is the whole reason to spend three rows on
## something one row can already say:
##
## ```nim
## echo bigDigits("12:34")
## ```
##
## ```
##  ╷  ╶─┐  ▪  ╶─┐ ╷ ╷
##  │  ┌─┘     ╶─┤ └─┤
##  ╵  └─╴  ▪  ╶─┘   ╵
## ```
##
## Every glyph is one of the shapes `nimtui/boxdraw <boxdraw.html>`_ generates —
## the thin set is that table at `lwThin` and the bold set is the same shapes at
## `lwHeavy` — so a font that draws this library's borders draws these too. They
## are written out rather than computed because a digit is a picture, and nine
## cells of picture per character is the clearest form for the thing that has to
## be checked by eye.
##
## Pure data and a block builder. Nothing here reads a terminal or emits an
## escape, and the only thing it depends on is `nimtui/width <width.html>`_ —
## which is not for rendering but for the assertion below, since "three columns"
## is the whole contract and a rune count cannot check it.

import std/[unicode, strutils]
import ./width

const
  DigitChars* = "0123456789 .,:-+=/xABCDEF"
    ## Every character these sets cover, in the order the tables below are
    ## written. Deliberately short: this is for numbers and the arithmetic
    ## around them, plus `A`-`F` so a hex figure works, and not a font.
    ##
    ## Anything else — a letter, a newline, a rune outside ASCII — draws as three
    ## spaces. That is the same reasoning `boxdraw`'s degradation follows: a
    ## missing glyph must still be exactly as wide as the one that was asked for,
    ## because the alternative is a block whose lines are different lengths. It
    ## also means a newline arriving in the argument cannot turn one block into
    ## two, which is the flattening problem solved by construction rather than by
    ## a pass over the string.

  ThinDigits*: array[DigitChars.len, array[3, string]] = [
    ["┌─┐", "│ │", "└─┘"],      # 0
    [" ╷ ", " │ ", " ╵ "],      # 1
    ["╶─┐", "┌─┘", "└─╴"],      # 2
    ["╶─┐", "╶─┤", "╶─┘"],      # 3
    ["╷ ╷", "└─┤", "  ╵"],      # 4
    ["┌─╴", "└─┐", "╶─┘"],      # 5
    ["┌─╴", "├─┐", "└─┘"],      # 6
    ["╶─┐", "  │", "  ╵"],      # 7
    ["┌─┐", "├─┤", "└─┘"],      # 8
    ["┌─┐", "└─┤", "╶─┘"],      # 9
    ["   ", "   ", "   "],      # space
    ["   ", "   ", " ▪ "],      # .
    ["   ", "   ", " ╷ "],      # ,
    [" ▪ ", "   ", " ▪ "],      # :
    ["   ", "╶─╴", "   "],      # -
    [" ╷ ", "╶┼╴", " ╵ "],      # +
    ["╶─╴", "   ", "╶─╴"],      # =
    ["  ╱", " ╱ ", "╱  "],      # /
    ["   ", " ╳ ", "   "],      # x
    ["┌─┐", "├─┤", "╵ ╵"],      # A
    ["╷  ", "├─┐", "└─┘"],      # B
    ["┌─╴", "│  ", "└─╴"],      # C
    ["  ╷", "┌─┤", "└─┘"],      # D
    ["┌─╴", "├─╴", "└─╴"],      # E
    ["┌─╴", "├─╴", "╵  "]]      # F
    ## `B` and `D` are the lower-case seven-segment shapes, because the upper
    ## case ones are `8` and `0` — a hex dump in which `B` cannot be told from
    ## `8` is worse than one whose letters are not all the same case.

  BoldDigits*: array[DigitChars.len, array[3, string]] = [
    ["┏━┓", "┃ ┃", "┗━┛"],      # 0
    [" ╻ ", " ┃ ", " ╹ "],      # 1
    ["╺━┓", "┏━┛", "┗━╸"],      # 2
    ["╺━┓", "╺━┫", "╺━┛"],      # 3
    ["╻ ╻", "┗━┫", "  ╹"],      # 4
    ["┏━╸", "┗━┓", "╺━┛"],      # 5
    ["┏━╸", "┣━┓", "┗━┛"],      # 6
    ["╺━┓", "  ┃", "  ╹"],      # 7
    ["┏━┓", "┣━┫", "┗━┛"],      # 8
    ["┏━┓", "┗━┫", "╺━┛"],      # 9
    ["   ", "   ", "   "],      # space
    ["   ", "   ", " ▪ "],      # .
    ["   ", "   ", " ╻ "],      # ,
    [" ▪ ", "   ", " ▪ "],      # :
    ["   ", "╺━╸", "   "],      # -
    [" ╻ ", "╺╋╸", " ╹ "],      # +
    ["╺━╸", "   ", "╺━╸"],      # =
    ["  ╱", " ╱ ", "╱  "],      # /
    ["   ", " ╳ ", "   "],      # x
    ["┏━┓", "┣━┫", "╹ ╹"],      # A
    ["╻  ", "┣━┓", "┗━┛"],      # B
    ["┏━╸", "┃  ", "┗━╸"],      # C
    ["  ╻", "┏━┫", "┗━┛"],      # D
    ["┏━╸", "┣━╸", "┗━╸"],      # E
    ["┏━╸", "┣━╸", "╹  "]]      # F
    ## Five of these are the same glyphs as the thin set — space, `.`, `:`, `/`
    ## and `x` — because Unicode has no heavy diagonal and no second weight of
    ## dot. `,` is the near miss that does differ, `╻` against `╷`, since its
    ## tail is a stub rather than a dot. `tdigits.nim` pins that list, so a
    ## sixth appearing on it means an entry was copied across and not edited.

  Blank = ["   ", "   ", "   "]
    ## What a character outside `DigitChars`_ draws as. Three columns like every
    ## other, which is the property that matters.

const DigitWidth* = 3
  ## Columns per character, before the gap between them. Exported because a
  ## caller sizing a panel around this needs it and computing it from the tables
  ## means indexing them.

static:
  # A row of the wrong width is three lines of different lengths, which is the
  # frame-desynchronising failure rather than a cosmetic one — and it is exactly
  # the mistake a hand-written picture invites, since the glyphs are multi-byte
  # and the rows line up in the source whether or not they line up in columns.
  #
  # Measured in *columns* rather than in runes, which is why this module depends
  # on `width` at all: a two-column rune slipped into one of these tables would
  # pass a rune count and wrap the line.
  doAssert ThinDigits.len == DigitChars.len
  doAssert BoldDigits.len == DigitChars.len
  for glyphs in [ThinDigits, BoldDigits]:
    for glyph in glyphs:
      for row in glyph:
        var w = 0
        for r in row.runes: w += runeWidth(r)
        doAssert w == DigitWidth, "not " & $DigitWidth & " columns: " & row
  # No character twice: `DigitChars.find` returns the first, so a duplicate
  # would make one of the two entries unreachable and nothing would say so.
  for i, c in DigitChars:
    doAssert DigitChars.find(c) == i

func digitGlyph*(r: Rune, bold = false): array[3, string] =
  ## The three rows for one character, or `Blank` for anything not in
  ## `DigitChars`_.
  ##
  ## `a`-`f` fold to `A`-`F` and `X` to `x`, so a hex string works whichever case
  ## it arrives in and `2X3` means what it looks like. Nothing else folds: the
  ## set is small enough that a near miss is better left blank than guessed at.
  if r.int32 > 0x7F: return Blank
  var c = char(r.int32)
  if c in {'a' .. 'f'}: c = char(ord(c) - 32)
  elif c == 'X': c = 'x'
  let i = DigitChars.find(c)
  if i < 0: Blank else: (if bold: BoldDigits[i] else: ThinDigits[i])

func bigDigits*(s: string, bold = false, gap = 1): string =
  ## `s` as a three-row block, one `\n`-joined string like every other block.
  ##
  ## Exactly `n * 3 + (n - 1) * gap` columns wide for `n` characters, on all
  ## three rows, whatever `s` contains — which is the property a caller laying
  ## this out depends on, and the one the `static:` block above exists to keep.
  ##
  ## The gap is a column of space between characters rather than part of the
  ## glyph, so `gap = 0` packs them and a digit's corners then touch its
  ## neighbour's. One is the default because that touching is what makes a
  ## bordered numeral read as a box instead of as a digit.
  var rows: array[3, string]
  var first = true
  for r in s.runes:
    let g = digitGlyph(r, bold)
    for i in 0 .. 2:
      if not first:
        for _ in 0 ..< gap: rows[i].add ' '
      rows[i].add g[i]
    first = false
  rows[0] & "\n" & rows[1] & "\n" & rows[2]
