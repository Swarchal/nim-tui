## A single-line text input.
##
## Stored as `seq[Rune]` so the cursor indexes characters, not bytes — a cursor
## kept as a byte offset lands in the middle of a multi-byte rune the first time
## someone types an accent.

import std/[unicode, sequtils]
import nimtui

type
  TextInput* = object
    runes*: seq[Rune]
    cursor*: int            ## 0 .. runes.len (one past the end is valid)
    placeholder*: string

proc initTextInput*(placeholder = ""): TextInput =
  TextInput(placeholder: placeholder)

proc text*(ti: TextInput): string =
  $ti.runes

proc `text=`*(ti: var TextInput, s: string) =
  ti.runes = s.toRunes
  ti.cursor = ti.runes.len

proc clear*(ti: var TextInput) =
  ti.runes.setLen 0
  ti.cursor = 0

proc isEmpty*(ti: TextInput): bool =
  ti.runes.len == 0

proc insert*(ti: var TextInput, r: Rune) =
  ti.runes.insert(r, ti.cursor)
  ti.cursor.inc

proc isWordRune(r: Rune): bool =
  not r.isWhiteSpace

proc wordLeft(ti: TextInput): int =
  var i = ti.cursor
  while i > 0 and not isWordRune(ti.runes[i - 1]): dec i
  while i > 0 and isWordRune(ti.runes[i - 1]): dec i
  i

proc wordRight(ti: TextInput): int =
  var i = ti.cursor
  while i < ti.runes.len and not isWordRune(ti.runes[i]): inc i
  while i < ti.runes.len and isWordRune(ti.runes[i]): inc i
  i

proc deleteWordBefore(ti: var TextInput) =
  # ctrl+w deletes exactly what alt+left would move over, so it asks `wordLeft`
  # rather than repeating the scan and risking the two drifting apart.
  let i = ti.wordLeft
  ti.runes.delete(i ..< ti.cursor)
  ti.cursor = i

proc handleKey*(ti: var TextInput, k: KeyMsg): bool =
  ## Apply an editing key. Returns false if the key means nothing here, so the
  ## caller can treat it as its own (enter to submit, esc to cancel, ...).
  result = true
  case $k
  of "left": ti.cursor = max(ti.cursor - 1, 0)
  of "right": ti.cursor = min(ti.cursor + 1, ti.runes.len)
  of "home", "ctrl+a": ti.cursor = 0
  of "end", "ctrl+e": ti.cursor = ti.runes.len
  of "alt+left", "ctrl+left": ti.cursor = ti.wordLeft
  of "alt+right", "ctrl+right": ti.cursor = ti.wordRight
  of "backspace":
    if ti.cursor > 0:
      ti.runes.delete(ti.cursor - 1)
      ti.cursor.dec
  of "delete":
    if ti.cursor < ti.runes.len: ti.runes.delete(ti.cursor)
  of "ctrl+w": ti.deleteWordBefore()
  of "ctrl+u":
    ti.runes.delete(0 ..< ti.cursor)
    ti.cursor = 0
  of "ctrl+k":
    ti.runes.setLen ti.cursor
  of "space": ti.insert Rune(' ')
  else:
    # Only bare (or shifted) printable runes are text; ctrl/alt combinations are
    # commands belonging to the application.
    if k.key == kRune and mCtrl notin k.mods and mAlt notin k.mods:
      ti.insert k.rune
    else:
      result = false

proc render*(ti: TextInput, width: int, focused = true): string =
  ## Draw the field, scrolling horizontally to keep the cursor in view. The
  ## cursor is drawn as a reverse-video cell rather than moved for real, so the
  ## renderer stays in charge of the terminal cursor.
  ##
  ## Pure: the scroll offset is derived from the cursor, so `view` procs need no
  ## mutable copy of the field.
  if width <= 0: return ""
  if ti.runes.len == 0 and not focused:
    return padVisible(Style().faint().render(
      truncateVisible(ti.placeholder, width)), width)

  # Scroll by columns, not runes. A double-width rune costs two cells, so a
  # rune-counted window renders wider than `width`, and since `padVisible` only
  # ever pads, the overflow escapes the field and pushes the surrounding border
  # off the edge of the line.
  #
  # Walk back from the cursor while cells remain — one is reserved for the
  # cursor block itself — to find the leftmost rune that can be shown with the
  # cursor still on screen.
  let cursorWidth =
    if ti.cursor < ti.runes.len: runeWidth(ti.runes[ti.cursor]) else: 1
  var offset = ti.cursor
  var used = cursorWidth
  while offset > 0:
    let w = runeWidth(ti.runes[offset - 1])
    if used + w > width: break
    used += w
    dec offset

  var visible = ""
  var col = 0
  for i in offset ..< ti.runes.len:
    let w = runeWidth(ti.runes[i])
    if col + w > width: break
    if focused and i == ti.cursor:
      visible.add Style().reverse().render($ti.runes[i])
    else:
      visible.add ti.runes[i]        # the Rune overload: no intermediate string
    col += w
  if focused and ti.cursor >= ti.runes.len and col < width:
    visible.add Style().reverse().render(" ")
  if ti.runes.len == 0 and ti.placeholder.len > 0:
    visible = Style().reverse().render(" ") &
      Style().faint().render(truncateVisible(ti.placeholder, width - 1))
  padVisible(visible, width)
