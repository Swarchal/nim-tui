## A read-only scrolling pane over a body of text: logs, help screens, output.
##
## ```nim
## var ta = initTextArea(width = 60, height = 20)
## ta.setText(readFile("README.md"))
##
## # in update
## discard ta.handleKey(key)
##
## # in view
## echo renderBox(ta.render(), 62, 22, title = "readme")
## ```
##
## **Wrapping is done when the text or the width changes, not when the pane is
## drawn.** `view` is a pure function of the model, so it cannot rebuild a
## cache; and re-wrapping ten thousand lines on every frame to show twenty of
## them is the kind of cost that only shows up once the log is long. Every proc
## that changes the content or the geometry — `setText`, `add`, `resize` — keeps
## the wrapped form up to date, so the only rule to remember is that a direct
## write to the `lines` field must be followed by `reflow`.
##
## For editing rather than reading, `nimtui/textinput <textinput.html>`_ is the
## single-line field; a multi-line editor is not built on this and would not
## want to be, since a cursor over soft-wrapped text needs the wrap points to be
## addressable rather than cached.

import std/strutils
import ./[ansi, style, spans, layout, viewport, messages]
# `messages` comes with it: `handleKey` takes a `KeyMsg`, so a caller cannot
# use this module without that type.
export style, viewport, messages

type
  TextArea* = object
    lines*: seq[string]        ## the source lines, unwrapped
    vp*: Viewport
    width*: int                ## total width including the scrollbar gutter
    wrap*: bool
    follow*: bool              ## stay pinned to the bottom as lines arrive
    showScrollbar*: bool
    xOffset*: int              ## horizontal scroll; only meaningful when not wrapping
    lineStyle*: Style
    scrollbarStyle*: Style
    wrapped: seq[string]       ## `lines` after wrapping — rebuilt by `reflow`

proc textWidth*(ta: TextArea): int =
  ## Columns available to the text itself, once the gutter is taken out.
  max(ta.width - (if ta.showScrollbar: 1 else: 0), 0)

proc reflow*(ta: var TextArea) =
  ## Rebuild the wrapped form. Called for you by everything in this module that
  ## changes the content or the width; call it yourself only after writing to
  ## `lines` directly.
  let w = ta.textWidth
  if not ta.wrap or w <= 0:
    ta.wrapped = ta.lines
  else:
    ta.wrapped = newSeqOfCap[string](ta.lines.len)
    for line in ta.lines:
      # An empty source line wraps to nothing, which would silently delete the
      # blank lines that separate paragraphs.
      if line.len == 0: ta.wrapped.add ""
      else: ta.wrapped.add wrapText(line, w)
  if ta.follow: ta.vp.toBottom ta.wrapped.len
  else: ta.vp.clampTop ta.wrapped.len

proc initTextArea*(width = 0, height = 0, wrap = true, follow = false,
                   showScrollbar = true): TextArea =
  result = TextArea(width: width, wrap: wrap, follow: follow,
                    showScrollbar: showScrollbar,
                    scrollbarStyle: Style().faint())
  result.vp = Viewport(height: height)

proc lineCount*(ta: TextArea): int =
  ## Number of lines after wrapping — what the scroll position is measured in.
  ta.wrapped.len

proc wrappedLines*(ta: TextArea): lent seq[string] =
  ## The wrapped lines, read-only.
  ##
  ## Scroll positions are indices into *this*, not into `lines`: once text is
  ## wrapped there is no longer a one-to-one correspondence, and a pager that
  ## wants to jump to a search hit has to find it in the wrapped form. Returned
  ## by `lent` so scanning it costs nothing — writing to it would desynchronise
  ## it from `lines`, hence read-only.
  ta.wrapped

proc setLines*(ta: var TextArea, lines: openArray[string]) =
  ta.lines = @lines
  ta.reflow()

proc setText*(ta: var TextArea, text: string) =
  ta.setLines text.split('\n')

proc add*(ta: var TextArea, line: string) =
  ## Append one line, wrapping just that line rather than the whole buffer —
  ## appending is what a log does thousands of times, and re-wrapping everything
  ## each time makes it quadratic.
  ta.lines.add line
  let w = ta.textWidth
  if not ta.wrap or w <= 0 or line.len == 0: ta.wrapped.add line
  else: ta.wrapped.add wrapText(line, w)
  if ta.follow: ta.vp.toBottom ta.wrapped.len

proc clear*(ta: var TextArea) =
  ta.lines.setLen 0
  ta.wrapped.setLen 0
  ta.vp.top = 0

proc resize*(ta: var TextArea, width, height: int) =
  ## Set the pane's geometry, re-wrapping if the width changed. Call this from
  ## the `WindowSizeMsg` branch of `update`.
  let changed = width != ta.width
  ta.width = width
  ta.vp.height = height
  if changed: ta.reflow()
  elif ta.follow: ta.vp.toBottom ta.wrapped.len
  else: ta.vp.clampTop ta.wrapped.len

# --- scrolling ----------------------------------------------------------------
#
# Wrappers rather than telling callers to reach into `.vp`, because each of them
# also has to re-decide whether the pane is still following the tail. Getting
# that wrong is the classic log-viewer bug: scroll up to read something, and the
# next arriving line yanks you back to the bottom.

proc syncFollow(ta: var TextArea) =
  ta.follow = ta.vp.atBottom(ta.wrapped.len)

proc scrollBy*(ta: var TextArea, delta: int) =
  ta.vp.scrollBy(delta, ta.wrapped.len)
  ta.syncFollow()

proc scrollTo*(ta: var TextArea, line: int) =
  ## Put wrapped line `line` at the top of the pane, clamped to the content.
  ## Indices are into `wrappedLines`, which is what a search hit is found in.
  ta.vp.top = line
  ta.vp.clampTop ta.wrapped.len
  ta.syncFollow()

proc centerOn*(ta: var TextArea, line: int) =
  ## Scroll so wrapped line `line` sits in the middle of the pane — what a
  ## search wants, since a hit pinned to the top row shows none of what led up
  ## to it.
  ta.scrollTo(line - ta.vp.height div 2)

proc pageUp*(ta: var TextArea) =
  ta.vp.pageUp ta.wrapped.len
  ta.syncFollow()

proc pageDown*(ta: var TextArea) =
  ta.vp.pageDown ta.wrapped.len
  ta.syncFollow()

proc halfPageUp*(ta: var TextArea) =
  ta.vp.halfPageUp ta.wrapped.len
  ta.syncFollow()

proc halfPageDown*(ta: var TextArea) =
  ta.vp.halfPageDown ta.wrapped.len
  ta.syncFollow()

proc toTop*(ta: var TextArea) =
  ta.vp.toTop()
  ta.follow = ta.vp.atBottom(ta.wrapped.len)

proc toBottom*(ta: var TextArea) =
  ta.vp.toBottom ta.wrapped.len
  ta.follow = true

proc atTop*(ta: TextArea): bool = ta.vp.atTop
proc atBottom*(ta: TextArea): bool = ta.vp.atBottom(ta.wrapped.len)

proc scrollFraction*(ta: TextArea): float =
  ta.vp.scrollFraction(ta.wrapped.len)

proc handleKey*(ta: var TextArea, k: KeyMsg): bool =
  ## Apply a scrolling key. Returns false if the key means nothing here, so the
  ## caller can treat it as its own — the same contract as `TextInput.handleKey
  ## <textinput.html#handleKey,TextInput,KeyMsg>`_.
  result = true
  case $k
  of "up", "k": ta.scrollBy(-1)
  of "down", "j": ta.scrollBy(1)
  of "pgup", "ctrl+b": ta.pageUp()
  of "pgdown", "ctrl+f": ta.pageDown()
  of "ctrl+u": ta.halfPageUp()
  of "ctrl+d": ta.halfPageDown()
  of "home", "g": ta.toTop()
  of "end", "G": ta.toBottom()
  of "left":
    # Only when not wrapping: with wrapping on there is nothing off-screen to
    # the right, so the key belongs to the application.
    if not ta.wrap and ta.xOffset > 0: dec ta.xOffset
    else: result = false
  of "right":
    if not ta.wrap: inc ta.xOffset
    else: result = false
  else: result = false

# --- rendering ----------------------------------------------------------------

proc render*(ta: TextArea): string =
  ## The visible window as a block of exactly `width` x `vp.height` cells,
  ## including the scrollbar gutter.
  let
    w = ta.textWidth
    h = ta.vp.height
  if h <= 0 or ta.width <= 0: return ""
  var rows = newSeq[string](h)
  for i in 0 ..< h:
    let idx = ta.vp.top + i
    var line = if idx >= 0 and idx < ta.wrapped.len: ta.wrapped[idx] else: ""
    # `sliceVisible` rather than `truncateVisible`, so a horizontally scrolled
    # pane keeps the styling that was in effect at the left edge of the window.
    if ta.xOffset > 0: line = sliceVisible(line, ta.xOffset, w)
    elif displayWidth(line) > w: line = truncateVisible(line, w)
    line = padVisible(line, w)
    rows[i] = if ta.lineStyle.isEmpty: line else: ta.lineStyle.render(line)
  if ta.showScrollbar:
    rows = ta.vp.withScrollbar(rows, ta.wrapped.len, ta.scrollbarStyle)
  rows.join("\n")

proc positionLabel*(ta: TextArea): string =
  ## `top`, `bot`, `all`, or a percentage — the label a pager puts in the corner.
  ## Handy as a `Panel` footer.
  if ta.wrapped.len <= ta.vp.height: "all"
  elif ta.atTop: "top"
  elif ta.atBottom: "bot"
  else: $(int(ta.scrollFraction * 100.0)) & "%"
