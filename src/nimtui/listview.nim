## A list with a highlighted row and a viewport that follows it.
##
## ```nim
## var lv = initListView(height = 10)
##
## # in update
## discard lv.handleKey(key, items.len)
##
## # in view
## echo lv.render(items, width = 30)
## ```
##
## The items are not stored. A list of files, a filtered list of todos and a
## list of search results all live in the model already, usually in a form the
## application needs for other reasons; copying them in here would mean keeping
## two versions in step. So every proc takes the count — or the items — as an
## argument, and `ListView` holds only the cursor and the window.
##
## That is also why `render` takes `openArray[string]`: whatever the model
## holds, formatting one item into a line is the application's business, and a
## stored formatting callback would be a closure in the model, which is exactly
## what `tests/manual/orc_closure_threads.nim` warns about.

import std/strutils
import ./[ansi, style, spans, viewport, messages]
# `messages` comes with it: `handleKey` takes a `KeyMsg`, so a caller cannot
# use this module without that type.
export style, viewport, messages

type
  ListView* = object
    cursor*: int               ## index of the highlighted item
    vp*: Viewport
    wrapAround*: bool          ## moving past either end jumps to the other

proc initListView*(height = 0, wrapAround = true): ListView =
  ListView(vp: Viewport(height: height), wrapAround: wrapAround)

proc sync*(l: var ListView, total: int) =
  ## Clamp the cursor to `total` and scroll the window to it. Call after the
  ## underlying list changes length — a filter narrowing to two items must not
  ## leave the cursor pointing at the twelfth.
  if total <= 0:
    l.cursor = 0
    l.vp.top = 0
    return
  l.cursor = clamp(l.cursor, 0, total - 1)
  l.vp.ensureVisible(l.cursor, total)

proc moveTo*(l: var ListView, index, total: int) =
  if total <= 0: return
  l.cursor = clamp(index, 0, total - 1)
  l.vp.ensureVisible(l.cursor, total)

proc moveBy*(l: var ListView, delta, total: int) =
  ## Move the cursor, wrapping at the ends when `wrapAround` is set.
  ##
  ## Wrapping uses `floorMod` semantics rather than a bare `mod`: a cursor at 0
  ## moving by -1 must land on the last item, and Nim's `mod` keeps the sign of
  ## the dividend, so the obvious spelling gives a negative index.
  if total <= 0: return
  var i = l.cursor + delta
  if l.wrapAround:
    i = i mod total
    if i < 0: i += total
  else:
    i = clamp(i, 0, total - 1)
  l.cursor = i
  l.vp.ensureVisible(l.cursor, total)

proc up*(l: var ListView, total: int) = l.moveBy(-1, total)
proc down*(l: var ListView, total: int) = l.moveBy(1, total)

proc pageUp*(l: var ListView, total: int) =
  ## A page of cursor movement, which is not the same as a page of scrolling:
  ## the cursor moves and the window follows, so the selection stays visible.
  l.moveTo(l.cursor - max(l.vp.height - 1, 1), total)

proc pageDown*(l: var ListView, total: int) =
  l.moveTo(l.cursor + max(l.vp.height - 1, 1), total)

proc toTop*(l: var ListView, total: int) = l.moveTo(0, total)
proc toBottom*(l: var ListView, total: int) = l.moveTo(total - 1, total)

proc handleKey*(l: var ListView, k: KeyMsg, total: int): bool =
  ## Apply a navigation key. Returns false if the key means nothing here, so
  ## enter, delete and the rest stay the application's — the same contract as
  ## `TextInput.handleKey <textinput.html#handleKey,TextInput,KeyMsg>`_.
  result = true
  if k.matches("up", "k", "ctrl+p"): l.up total
  elif k.matches("down", "j", "ctrl+n"): l.down total
  elif k.matches("pgup", "ctrl+b"): l.pageUp total
  elif k.matches("pgdown", "ctrl+f"): l.pageDown total
  elif k.matches("home", "g"): l.toTop total
  elif k.matches("end", "G"): l.toBottom total
  else: result = false

proc render*(l: ListView, items: openArray[string], width: int,
             selectedStyle = Style().reverse(), itemStyle = Style(),
             selectedPrefix = "▌", prefix = " ",
             showScrollbar = true, scrollbarStyle = Style().faint(),
             zebra = Style()): string =
  ## The visible window as a block of exactly `width` x `vp.height` cells.
  ##
  ## The selected row is drawn across its whole width, gutter included, so a
  ## highlight reads as a bar rather than as coloured text with ragged ends.
  ##
  ## `zebra` is laid over alternate rows — the same idea as `Table.zebra
  ## <table.html#Table>`_, and usually a background colour a step off the page.
  ## It stripes by *item* index rather than by screen row, so the bands belong to
  ## the data and do not crawl as the window scrolls, and the selected row is
  ## never striped: two backgrounds on one row means the highlight reads as two
  ## different colours depending on which item the cursor happens to be on.
  let h = l.vp.height
  if h <= 0 or width <= 0: return ""
  let
    gutterW = if showScrollbar: 1 else: 0
    rowW = max(width - gutterW, 0)
    markW = max(displayWidth(selectedPrefix), displayWidth(prefix))
    textW = max(rowW - markW, 0)
  var rows = newSeq[string](h)
  for i in 0 ..< h:
    let idx = l.vp.top + i
    if idx < 0 or idx >= items.len:
      rows[i] = spaces(rowW)
      continue
    let selected = idx == l.cursor
    let st =
      if selected: selectedStyle
      elif idx mod 2 == 1: itemStyle.merge(zebra)
      else: itemStyle
    var line: Spans
    line.add(padVisible(if selected: selectedPrefix else: prefix, markW), st)
    line.add(padVisible(truncateVisible(items[idx], textW), textW), st)
    rows[i] = line.render()
  if showScrollbar:
    rows = l.vp.withScrollbar(rows, items.len, scrollbarStyle)
  rows.join("\n")
