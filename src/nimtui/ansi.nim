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

  ## SGR mouse reporting, in three levels: button events only (1000), plus
  ## motion while a button is held (1002), plus motion with none held (1003).
  ## `tty.MouseTracking` selects among them; 1006 is the SGR encoding, which is
  ## what makes coordinates past column 223 representable and is wanted at every
  ## level. Note the wheel is reported at all three — xterm sends it as a press
  ## of button 4 or 5 — so an application that only scrolls wants the first.
  ##
  ## `DisableMouse` turns off all three whichever was on, so it is the whole of
  ## the teardown for any of them.
  EnableMouse* = Csi & "?1000h" & Csi & "?1006h"
  EnableMouseCellMotion* = Csi & "?1002h" & Csi & "?1006h"
  EnableMouseAllMotion* = Csi & "?1003h" & Csi & "?1006h"
  DisableMouse* = Csi & "?1006l" & Csi & "?1003l" & Csi & "?1002l" & Csi & "?1000l"

  ## Bracketed paste (DEC private mode 2004). With it on, the terminal wraps
  ## pasted text in the two markers below, which is the only thing that tells a
  ## paste apart from someone typing very fast.
  EnableBracketedPaste* = Csi & "?2004h"
  DisableBracketedPaste* = Csi & "?2004l"

  ## Focus reporting (DEC private mode 1004): `CSI I` when the window gains
  ## focus, `CSI O` when it loses it.
  EnableFocusReporting* = Csi & "?1004h"
  DisableFocusReporting* = Csi & "?1004l"

  ## Auto-wrap (DECAWM, mode 7). With it *off*, a glyph written past the right
  ## margin is dropped instead of continuing on the next row — which is the one
  ## thing that stops a single mis-measured line from dragging every row below it
  ## out of step. Every other invariant in this library is about never emitting
  ## such a line; this is what happens when one gets through anyway.
  EnableLineWrap* = Csi & "?7h"
  DisableLineWrap* = Csi & "?7l"

proc cursorUp*(n: int): string =
  if n <= 0: "" else: Csi & $n & "A"

proc cursorDown*(n: int): string =
  if n <= 0: "" else: Csi & $n & "B"

proc cursorTo*(row, col: int): string =
  Csi & $row & ";" & $col & "H"

proc link*(text, url: string, id = ""): string =
  ## `text` as an OSC 8 hyperlink to `url`. Terminals that do not implement it
  ## show the text and ignore the rest.
  ##
  ## Costs no columns, and that falls out of what is already here rather than
  ## needing anything new: `escapeLen <#escapeLen,string,int>`_ treats OSC as a
  ## string sequence, so `displayWidth <#displayWidth,string>`_ already measures
  ## one of these as just its text. That is what makes a link usable in a table
  ## cell or a status bar without the layout drifting.
  ##
  ## `id` is the optional identifier that lets a terminal treat several runs as
  ## one link — worth setting when a link is split across lines by
  ## `wrapText <layout.html#wrapText,string,int>`_, since a terminal has no other
  ## way to know the halves belong together and will underline them separately
  ## on hover.
  ##
  ## It goes out as `id=<value>`, which is the part that is easy to get wrong and
  ## impossible to notice: the field before the URL is a `:`-separated list of
  ## `key=value` pairs, not a bare value, and `id` is the only key defined. A
  ## terminal looks for the `id=`, so writing the value on its own is not a
  ## differently-spelled identifier but no identifier at all — the sequence stays
  ## well formed, the link still works, and the one thing the parameter exists
  ## for silently does not happen.
  ##
  ## Both parameters are sent verbatim apart from the bytes that would end the
  ## sequence early or be read as structure: a `;` in a URL is legal and would
  ## otherwise be read as the end of the parameter list, an `ESC` or `BEL` would
  ## terminate the sequence in the middle of the address, and a `:` or `=` in an
  ## `id` would start a key the terminal does not know. They are dropped rather
  ## than percent-encoded, since encoding a URL that is already encoded corrupts
  ## it and this cannot tell the two apart.
  var clean = newStringOfCap(url.len)
  for c in url:
    if c notin {';', Esc, '\a'}: clean.add c
  result = "\e]8;"
  if id.len > 0:
    result.add "id="
    for c in id:
      if c notin {';', ':', '=', Esc, '\a'}: result.add c
  result.add ';'
  result.add clean
  result.add "\e\\"
  result.add text
  result.add "\e]8;;\e\\"

proc isFinalByte*(c: char): bool =
  ## True for the terminating byte of a CSI sequence (`@` through `~`).
  c.ord in 0x40 .. 0x7E

const StringIntroducers* = {']', 'P', 'X', '^', '_'}
  ## The introducers of a *string* escape sequence: OSC, DCS, SOS, PM and APC.
  ## All five carry a payload of arbitrary length and end at a terminator rather
  ## than at a final byte, which is what separates them from CSI. Named because
  ## `escapeLen <#escapeLen,string,int>`_ and the input decoder have to agree
  ## about which sequences those are — a sequence measured as two bytes here and
  ## consumed whole there, or the reverse, is a desynchronised stream.

const
  PasteStart* = Csi & "200~"
  PasteEnd* = Csi & "201~"
    ## The markers `EnableBracketedPaste <#EnableBracketedPaste>`_ wraps pasted
    ## text in. Named here for the same reason as `StringIntroducers`_ above: the
    ## input decoder is the one that acts on them, but the bytes have to be
    ## agreed in one place.
    ##
    ## Note that `escapeLen`_ deliberately does *not* treat a paste as one
    ## sequence, which is the one place it and the decoder disagree on purpose.
    ## They scan different streams: `escapeLen` measures view strings about to be
    ## drawn, where these markers never appear, while the decoder scans the input
    ## stream, where they do. If one somehow did reach a view string, measuring
    ## it as a six-byte CSI and the payload after it as visible text is the right
    ## answer.

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
  of StringIntroducers:               # OSC/DCS/SOS/PM/APC: terminated by ST or BEL
    # All five together, not OSC alone. A DCS measured as two bytes — which is
    # what this did — leaves its payload to be counted as visible text, so a
    # `\ePtmux;…\e\\` passthrough wrapper, a sequence an application has every
    # reason to emit, measured as forty-odd columns of nothing.
    #
    # BEL officially terminates only OSC; accepted for all five here because
    # nothing else ends a string sequence, so it can only shorten one that was
    # already malformed. The known limit is the other direction: a payload
    # carrying *doubled* escapes, as tmux's passthrough wrapper does, ends at the
    # first `\e\\` this finds inside it rather than at the real one. Undoing that
    # doubling is tmux's convention rather than the terminal's, and does not
    # belong in a general scanner — the result is short, where it used to be two.
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

proc needsFlattening(s: string): bool =
  ## Is there a control character in `s` that `oneLine` would replace?
  ##
  ## A byte scan rather than a rune walk, because this is the fast path and the
  ## answer is almost always no. `ESC` is skipped rather than counted: it is a
  ## control character, but it is the one that legitimately appears in styled
  ## text, and `oneLine` hands it to `escapeLen` instead of replacing it.
  ##
  ## The `\xC2` case is the C1 controls, U+0080 to U+009F, which encode as `\xC2`
  ## and a byte in that range — U+0085 is NEL and breaks a line exactly as `\n`
  ## does. Checking the second byte as well as the first is what keeps `©` and
  ## `°`, which also begin `\xC2`, on the fast path.
  for i in 0 ..< s.len:
    let c = s[i]
    if c == Esc: continue
    if c < ' ' or c == '\x7f': return true
    if c == '\xc2' and i + 1 < s.len and s[i + 1] in '\x80' .. '\x9f':
      return true
  false

proc oneLine*(s: string): string =
  ## `s` with every control character replaced by a space, escape sequences left
  ## intact.
  ##
  ## For text that is about to become *one line* of a frame and came from
  ## somewhere that does not know that — a log message, an exception's `msg`, a
  ## filename, anything a user or another program chose. A newline in such a
  ## string is measured by `displayWidth` as nothing at all and drawn by the
  ## terminal as a line break, so the frame comes out taller than the layout
  ## counted and every line below it lands a row late. That failure is invisible
  ## to a dimensional assertion: each line really is the right width.
  ##
  ## **Flatten before measuring, never after.** A control character is zero
  ## columns and a space is one, so this does not preserve width — it is a step
  ## that has to happen before anything is fitted, padded or aligned. Every
  ## helper here that fits text to a width does it on the way in; see the note in
  ## `nimtui/spans <spans.html>`_.
  ##
  ## A space rather than nothing, because the usual input is a stack trace and
  ## dropping the newlines runs the last word of one line into the first of the
  ## next. Escapes survive because pre-styled text is normal — a `Table` cell
  ## carrying its own colour is the documented way to colour one cell — and `ESC`
  ## is itself a control character, so flattening bytes naively would dismantle
  ## every sequence in the string.
  ##
  ## Nearly every call has nothing to do — this runs twice per cell per frame
  ## from `Table` alone — so the common case is a byte scan that allocates
  ## nothing and returns the string it was given. Measured on a 40-row frame,
  ## the rune-walking version of that check cost about as much again as the
  ## `displayWidth` beside it; this one does not show up.
  if not s.needsFlattening: return s
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let n = escapeLen(s, i)
    if n > 0:
      result.addSlice s, i, i + n - 1
      i += n
      continue
    let start = i
    var r: Rune
    fastRuneAt(s, i, r, true)
    if r.isControl: result.add ' '
    else: result.addSlice s, start, i - 1

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

proc sliceVisible*(s: string, start, width: int): string =
  ## The `width` visible columns of `s` starting at column `start`.
  ##
  ## `truncateVisible` takes a prefix; this takes a window, which is what
  ## drawing something *over* a line needs — the part of the line to the right
  ## of the overlay. Shorter than `width` if `s` runs out first, exactly like
  ## `truncateVisible` on a short string.
  ##
  ## Escape sequences from *before* `start` are kept and emitted at the front of
  ## the result. That is the whole difficulty of slicing styled text: a window
  ## into the middle of a coloured run begins with no colour of its own, so
  ## dropping the escapes that preceded it renders the tail of the line
  ## unstyled. Carrying them forward restores the state the terminal would have
  ## been in at that column.
  ##
  ## A double-width rune straddling either edge becomes a space, so the result
  ## is exactly `width` columns whenever `s` extends that far — the same
  ## guarantee `truncateVisible` makes, and for the same reason.
  if width <= 0 or start < 0: return ""
  result = newStringOfCap(s.len)
  var
    i = 0
    col = 0                       # visible column of the rune about to be read
    shown = 0                     # columns emitted so far
    stopped = false
  while i < s.len:
    let n = escapeLen(s, i)
    if n > 0:
      result.addSlice s, i, i + n - 1
      i += n
      continue
    let b = i
    var r: Rune
    fastRuneAt(s, i, r, true)
    if stopped: continue          # keep scanning, but only for escapes
    let
      rw = runeWidth(r)
      cellStart = col
    col += rw
    if col <= start and rw > 0:
      continue                    # entirely to the left of the window
    if cellStart < start:
      # Straddles the left edge: only its right-hand cells are in view, and half
      # a glyph cannot be drawn, so blank them.
      for _ in 0 ..< min(col - start, width - shown):
        result.add ' '
        inc shown
    elif shown + rw <= width:
      result.addSlice s, b, i - 1
      shown += rw
    else:
      # Straddles the right edge; blank to the boundary so the width is exact.
      while shown < width:
        result.add ' '
        inc shown
      stopped = true
    if shown >= width: stopped = true

proc padVisible*(s: string, width: int): string =
  ## `s` padded with spaces to `width` visible columns (never truncated).
  let w = displayWidth(s)
  if w >= width: s else: s & ' '.repeat(width - w)
