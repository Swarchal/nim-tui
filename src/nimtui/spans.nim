## One line of text carrying several styles, measured and cut as a unit.
##
## A `Spans` is a sequence of `(text, Style)` runs. It exists because the
## alternative — concatenating `Style().fg(c).render(part)` by hand — produces a
## string that is *already* full of escape sequences, and every subsequent
## measurement of it has to scan past them. Building the line as runs keeps the
## text and the styling separate until the moment it is rendered, so truncating
## a multi-coloured line cannot cut a colour in half.
##
## ```nim
## var line: Spans
## line.add("ERROR ", Style().fg(hex"#f85149").bold())
## line.add("upstream timeout")
## echo line.fit(30).render()
## ```
##
## **A `Spans` is a line, not a block.** It holds no newlines and knows nothing
## about height; `render` turns it into an ordinary string, which is what every
## helper in `nimtui/layout <layout.html>`_ takes. Build lines with `Spans`,
## compose blocks with strings.

import std/[strutils, unicode]
import ./[ansi, style]
export style

type
  Align* = enum
    ## Where content sits within a wider field. Declared here because this is
    ## the lowest layer that needs it; `nimtui/layout <layout.html>`_ re-exports
    ## it for titles and table columns.
    aLeft, aCenter, aRight

  Span* = object
    text*: string
    style*: Style

  Spans* = object
    items*: seq[Span]

# --- building -----------------------------------------------------------------

proc span*(text: string, style = Style()): Spans =
  ## A one-run line, the usual starting point for `&`.
  Spans(items: @[Span(text: text, style: style)])

proc add*(s: var Spans, text: string, style = Style()) =
  ## Append a run. Empty text is dropped rather than stored, so a conditional
  ## `add(maybeEmpty, st)` cannot leave a run that renders as a bare
  ## on/off escape pair.
  if text.len > 0:
    s.items.add Span(text: text, style: style)

proc add*(s: var Spans, other: Spans) =
  for sp in other.items: s.items.add sp

proc `&`*(a, b: Spans): Spans =
  result.items = newSeqOfCap[Span](a.items.len + b.items.len)
  for sp in a.items: result.items.add sp
  for sp in b.items: result.items.add sp

proc `&`*(a: Spans, b: string): Spans =
  result = a
  result.add b

proc `&`*(a: string, b: Spans): Spans =
  result = span(a)
  result.add b

proc isEmpty*(s: Spans): bool =
  for sp in s.items:
    if sp.text.len > 0: return false
  true

# --- measuring and cutting ----------------------------------------------------

proc displayWidth*(s: Spans): int =
  ## Total visible width. Overloads `displayWidth
  ## <ansi.html#displayWidth,string>`_ so code that measures a line does not
  ## care which of the two it was handed.
  for sp in s.items: result += displayWidth(sp.text)

proc text*(s: Spans): string =
  ## The unstyled text, with no escape sequences at all.
  var bytes = 0
  for sp in s.items: bytes += sp.text.len
  result = newStringOfCap(bytes)
  for sp in s.items: result.add sp.text

proc truncate*(s: Spans, width: int): Spans =
  ## Cut to `width` visible columns, dropping whole runs past the cut and
  ## trimming the run the cut lands in. Follows `truncateVisible
  ## <ansi.html#truncateVisible,string,int>`_ exactly, including replacing a
  ## straddling double-width rune with a space, so the result is `width` columns
  ## whenever the input was at least that wide.
  if width <= 0: return Spans()
  var remaining = width
  for sp in s.items:
    if remaining <= 0: break
    let w = displayWidth(sp.text)
    if w <= remaining:
      result.items.add sp
      remaining -= w
    else:
      let cut = truncateVisible(sp.text, remaining)
      result.items.add Span(text: cut, style: sp.style)
      break

proc pad*(s: Spans, width: int, style = Style(), align = aLeft): Spans =
  ## Pad to `width` columns with spaces. Never truncates — see `fit`.
  ##
  ## The padding carries its own style so a filled background extends across the
  ## whole field; left at the default it is plain, which is what an uncoloured
  ## line wants.
  let w = s.displayWidth
  if w >= width: return s
  let slack = width - w
  case align
  of aLeft:
    result = s
    result.items.add Span(text: spaces(slack), style: style)
  of aRight:
    result.items = @[Span(text: spaces(slack), style: style)]
    for sp in s.items: result.items.add sp
  of aCenter:
    let left = slack div 2
    result.items = @[Span(text: spaces(left), style: style)]
    for sp in s.items: result.items.add sp
    result.items.add Span(text: spaces(slack - left), style: style)

proc fit*(s: Spans, width: int, style = Style(), align = aLeft): Spans =
  ## Exactly `width` columns: truncated if too long, padded if too short.
  if s.displayWidth > width: s.truncate(width) else: s.pad(width, style, align)

proc elide*(s: Spans, width: int, ellipsis = "…", style = Style()): Spans =
  ## Truncate with a marker, so a cut line is distinguishable from a short one.
  ## The marker takes the given style, defaulting to plain rather than
  ## inheriting whichever run happened to be cut.
  if width <= 0: return Spans()
  if s.displayWidth <= width: return s
  let keep = width - displayWidth(ellipsis)
  if keep <= 0: return span(truncateVisible(ellipsis, width), style)
  result = s.truncate(keep)
  result.items.add Span(text: ellipsis, style: style)

# --- rendering ----------------------------------------------------------------

proc render*(s: Spans): string =
  ## Collapse to a plain string with escape sequences in place.
  ##
  ## Adjacent runs sharing a style are emitted under one escape pair. That is
  ## not a micro-optimisation: `gradientSpans` produces one run per rune, and
  ## without coalescing a 200-column line of near-identical colours would carry
  ## 200 redundant on/off pairs — several kilobytes per line, all of it churned
  ## through the renderer's per-line compare every frame.
  ##
  ## A run's text may arrive with escapes already in it — a table cell the
  ## caller coloured, a message with a highlight in it. The reset that ends
  ## *its* styling ends this run's too, since a reset clears everything, so the
  ## run's style is re-armed after each one. Without that, a span setting a
  ## background is only painted as far as the first embedded reset and the rest
  ## of it is a hole in the colour.
  var bytes = 0
  for sp in s.items: bytes += sp.text.len + 8
  result = newStringOfCap(bytes)
  var i = 0
  while i < s.items.len:
    var j = i + 1
    while j < s.items.len and s.items[j].style == s.items[i].style: inc j
    let on = s.items[i].style.sgr()
    if on.len > 0: result.add on
    for k in i ..< j:
      let text = s.items[k].text
      # The `contains` is what keeps the common case — text with no escapes at
      # all — from allocating a copy of every run.
      if on.len > 0 and Reset in text: result.add text.replace(Reset, Reset & on)
      else: result.add text
    if on.len > 0: result.add Reset
    i = j

proc `$`*(s: Spans): string = s.render()

# --- gradients ----------------------------------------------------------------

proc gradientSpans*(text: string, g: Gradient, base = Style(),
                    background = false): Spans =
  ## One run per rune, coloured along `g` from the first column to the last.
  ##
  ## Ramped over *columns*, not runes, so a line mixing narrow and double-width
  ## characters still spreads the gradient evenly across the field rather than
  ## bunching it wherever the wide characters are. `base` supplies the
  ## attributes (bold, italic) that every run shares; `background` ramps the
  ## background colour instead of the foreground.
  if text.len == 0 or g.isEmpty: return span(text, base)
  let total = displayWidth(text)
  if total <= 0: return span(text, base)

  result.items = newSeqOfCap[Span](total)
  var
    i = 0
    col = 0
  while i < text.len:
    let n = escapeLen(text, i)
    if n > 0:
      # Pass an existing escape through untouched: it belongs to the caller's
      # own styling and takes no columns, so it must not advance the ramp.
      var raw = newStringOfCap(n)
      for k in i ..< i + n: raw.add text[k]
      result.items.add Span(text: raw, style: Style())
      i += n
      continue
    let start = i
    var r: Rune
    fastRuneAt(text, i, r, true)
    let t = if total <= 1: 0.0 else: col.float / (total - 1).float
    let c = g.at(t)
    var piece = newStringOfCap(i - start)
    for k in start ..< i: piece.add text[k]
    result.items.add Span(text: piece,
                          style: if background: base.bg(c) else: base.fg(c))
    col += runeWidth(r)

proc gradientText*(text: string, g: Gradient, base = Style(),
                   background = false): string =
  ## `gradientSpans` rendered straight to a string, for dropping into a view.
  ##
  ## ```nim
  ## echo gradientText("nimtui", SunsetGradient, Style().bold())
  ## ```
  gradientSpans(text, g, base, background).render()
