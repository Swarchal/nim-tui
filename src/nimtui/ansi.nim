## Raw ANSI escape-sequence primitives, plus width-aware string helpers.
##
## Everything here is pure: no terminal is touched. The renderer needs to know
## how wide a styled string *looks* (escape sequences occupy no columns), so
## that logic lives here where it can be tested without a tty.

import std/[strutils, unicode]
import ./width
export width

const
  Esc* = '\e'
  Csi* = "\e["

  ShowCursor* = Csi & "?25h"
  HideCursor* = Csi & "?25l"
  EnterAltScreen* = Csi & "?1049h"
  ExitAltScreen* = Csi & "?1049l"
  EraseLine* = Csi & "2K"
  EraseLineRight* = Csi & "K"   ## erase from the cursor to the end of the line
  EraseDown* = Csi & "J"
  Reset* = Csi & "0m"

  ## Synchronized output (DEC private mode 2026): tells the terminal to hold its
  ## display steady until the frame is complete, instead of refreshing on its own
  ## clock partway through. Terminals that do not implement it ignore the mode,
  ## as they must for any private mode they do not recognise.
  BeginSyncUpdate* = Csi & "?2026h"
  EndSyncUpdate* = Csi & "?2026l"

  ## SGR mouse reporting: button events plus cell-motion / any-motion variants.
  EnableMouse* = Csi & "?1000h" & Csi & "?1006h"
  EnableMouseCellMotion* = Csi & "?1002h" & Csi & "?1006h"
  EnableMouseAllMotion* = Csi & "?1003h" & Csi & "?1006h"
  DisableMouse* = Csi & "?1006l" & Csi & "?1003l" & Csi & "?1002l" & Csi & "?1000l"

proc cursorUp*(n: int): string =
  if n <= 0: "" else: Csi & $n & "A"

proc cursorDown*(n: int): string =
  if n <= 0: "" else: Csi & $n & "B"

proc cursorTo*(row, col: int): string =
  Csi & $row & ";" & $col & "H"

proc isFinalByte*(c: char): bool =
  ## True for the terminating byte of a CSI sequence (`@` through `~`).
  c.ord in 0x40 .. 0x7E

proc escapeLen*(s: string, i: int): int =
  ## Length in bytes of the escape sequence starting at `s[i]`, or 0 if there
  ## is no escape sequence there. An unterminated sequence returns the number
  ## of bytes available, so scanning always makes progress.
  if i >= s.len or s[i] != Esc: return 0
  var j = i + 1
  if j >= s.len: return 1
  case s[j]
  of '[':                             # CSI: params then a final byte
    inc j
    while j < s.len and not isFinalByte(s[j]): inc j
    if j < s.len: inc j
    result = j - i
  of ']':                             # OSC: terminated by BEL or ST
    inc j
    while j < s.len:
      if s[j] == '\a':
        inc j
        break
      if s[j] == Esc and j + 1 < s.len and s[j + 1] == '\\':
        j += 2
        break
      inc j
    result = j - i
  else:                               # two-byte sequence, e.g. ESC M
    result = 2

proc stripAnsi*(s: string): string =
  ## `s` with every escape sequence removed.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let n = escapeLen(s, i)
    if n > 0:
      i += n
    else:
      result.add s[i]
      inc i

proc displayWidth*(s: string): int =
  ## Number of terminal columns `s` occupies, ignoring escape sequences.
  ##
  ## Columns, not runes: see `runeWidth <width.html#runeWidth,Rune>`_ for how
  ## wide and zero-width codepoints are classified.
  var i = 0
  while i < s.len:
    let n = escapeLen(s, i)
    if n > 0:
      i += n
    else:
      var r: Rune
      fastRuneAt(s, i, r, true)
      result += runeWidth(r)

proc addSlice(dest: var string, src: string, first, last: int) {.inline.} =
  ## Append `src[first .. last]`.
  ##
  ## Not `dest.add src[first .. last]`: that materialises a temporary string, and
  ## in a loop that runs once per rune it costs an allocation per character —
  ## which measured as 15x the cost of the same walk done without copying.
  for k in first .. last:
    dest.add src[k]

proc truncateVisible*(s: string, width: int): string =
  ## `s` cut to `width` visible columns. Escape sequences are always kept, even
  ## past the cut, so trailing resets still apply and colours do not bleed.
  ##
  ## The cut never lands inside a double-width rune. One that would straddle the
  ## boundary is replaced by a space, so the result is exactly `width` columns
  ## rather than one short — callers doing column arithmetic can rely on
  ## `displayWidth(truncateVisible(s, w)) == w` whenever `s` is at least that
  ## wide.
  if width <= 0: return ""
  result = newStringOfCap(s.len)
  var i = 0
  var w = 0
  var stopped = false
  while i < s.len:
    let n = escapeLen(s, i)
    if n > 0:
      result.addSlice s, i, i + n - 1
      i += n
    else:
      let start = i
      var r: Rune
      fastRuneAt(s, i, r, true)
      if stopped: continue
      let rw = runeWidth(r)
      if w + rw <= width:
        result.addSlice s, start, i - 1
        w += rw
      else:
        # Past the cut. Everything visible from here is dropped, including any
        # combining marks, which would otherwise reattach to the wrong base.
        stopped = true
        if w < width:
          result.add ' '
          inc w

proc padVisible*(s: string, width: int): string =
  ## `s` padded with spaces to `width` visible columns (never truncated).
  let w = displayWidth(s)
  if w >= width: s else: s & ' '.repeat(width - w)
