## A single-line text input.
##
## Stored as `seq[Rune]` so the cursor indexes characters, not bytes — a cursor
## kept as a byte offset lands in the middle of a multi-byte rune the first time
## someone types an accent.

import std/[unicode, sequtils]
import ./[ansi, style, messages]
# `messages` comes with it: `handleKey` takes a `KeyMsg`, so a caller cannot
# use this module without that type.
export style, messages

type
  TextInput* = object
    runes*: seq[Rune]
    cursor*: int            ## 0 .. runes.len (one past the end is valid)
    placeholder*: string
    mask*: Rune
      ## Drawn in place of every rune when set, for a password field. `Rune(0)`
      ## — the zero value, so a field is unmasked unless asked — means off.
      ##
      ## Affects `render <#render,TextInput,int>`_ and nothing else: `text` still
      ## returns what was typed, which is the point. Note that the mask is what
      ## gets *measured* as well as drawn, so a wide mask rune on a narrow field
      ## shows fewer characters than an unmasked one would.

proc initTextInput*(placeholder = "", mask = Rune(0)): TextInput =
  TextInput(placeholder: placeholder, mask: mask)

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

proc insert*(ti: var TextInput, s: string) =
  ## Insert `s` at the cursor in one move — what a paste arrives as.
  ##
  ## Control characters become spaces, escapes included. This is CLAUDE.md's
  ## flatten-before-you-measure rule at the one boundary that owns runes rather
  ## than strings, which is also why `ansi.oneLine` is the wrong tool: it
  ## preserves escape sequences, and an `ESC` sitting in `runes` is not styling —
  ## it is a rune that `render` counts as a column and the terminal draws as
  ## nothing, so the field comes out narrow. A space rather than nothing, for
  ## `oneLine`'s reason: dropping a newline runs the last word of one line into
  ## the first of the next.
  var rs = newSeqOfCap[Rune](s.len)
  for r in s.runes:
    rs.add(if r.isControl: Rune(' ') else: r)
  if rs.len == 0: return
  # One shift of the tail, not one per rune. `seq.insert` moves everything after
  # the cursor for each rune inserted, which on a 4 KB paste is millions of
  # moves — the quadratic half of the bug bracketed paste exists to fix.
  let old = ti.runes.len
  ti.runes.setLen old + rs.len
  if old > ti.cursor:
    moveMem(addr ti.runes[ti.cursor + rs.len], addr ti.runes[ti.cursor],
            (old - ti.cursor) * sizeof(Rune))
  for i, r in rs: ti.runes[ti.cursor + i] = r
  ti.cursor += rs.len

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

proc handle*(ti: var TextInput, msg: Msg): bool =
  ## `handleKey <#handleKey,TextInput,KeyMsg>`_ widened to any message, so a
  ## field picks up pasted text without every caller having to remember to wire
  ## it. Same contract: false means the message meant nothing here.
  ##
  ## Only `TextInput` has one. `Viewport`, `ListView` and `TextArea` consume no
  ## text, so for them this would never do anything `handleKey` does not — a
  ## deliberate omission rather than one to fill in later.
  if msg of PasteMsg:
    ti.insert PasteMsg(msg).text
    true
  elif msg of KeyMsg:
    ti.handleKey KeyMsg(msg)
  else:
    false

proc render*(ti: TextInput, width: int, focused = true): string =
  ## Draw the field, scrolling horizontally to keep the cursor in view. The
  ## cursor is drawn as a reverse-video cell rather than moved for real, so the
  ## renderer stays in charge of the terminal cursor.
  ##
  ## Pure: the scroll offset is derived from the cursor, so `view` procs need no
  ## mutable copy of the field.
  ##
  ## Every rune is read through `shown`, never out of `runes` directly, so a
  ## mask is measured as well as drawn. Taking the width from the real rune and
  ## drawing the mask would size the window for text that is not on screen —
  ## which for a masked CJK password is a field that renders half as wide as it
  ## claims, and per the no-wrap rule that desynchronises the whole frame rather
  ## than one line.
  template shown(i: int): Rune =
    if ti.mask == Rune(0): ti.runes[i] else: ti.mask

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
    if ti.cursor < ti.runes.len: runeWidth(shown(ti.cursor)) else: 1
  var offset = ti.cursor
  var used = cursorWidth
  while offset > 0:
    let w = runeWidth(shown(offset - 1))
    if used + w > width: break
    used += w
    dec offset

  var visible = ""
  var col = 0
  for i in offset ..< ti.runes.len:
    let r = shown(i)
    let w = runeWidth(r)
    if col + w > width: break
    if focused and i == ti.cursor:
      visible.add Style().reverse().render($r)
    else:
      visible.add r                  # the Rune overload: no intermediate string
    col += w
  if focused and ti.cursor >= ti.runes.len and col < width:
    visible.add Style().reverse().render(" ")
  if ti.runes.len == 0 and ti.placeholder.len > 0:
    visible = Style().reverse().render(" ") &
      Style().faint().render(truncateVisible(ti.placeholder, width - 1))
  padVisible(visible, width)
