## A scrolling window over a list of items, plus a scrollbar gutter.
##
## The state is two integers — where the window starts and how tall it is — and
## every operation is derived from those, so a `Viewport` can live in a model
## and be copied about freely. It knows nothing about what it is scrolling over:
## `window <#window,Viewport,openArray[T]>`_ is generic, and the total item
## count is passed in rather than held, which is what lets one viewport scroll a
## list that another part of the model owns.
##
## ```nim
## var vp = Viewport(height: 10)
## vp.ensureVisible(cursor, items.len)
## for item in vp.window(items):
##   echo item
## ```
##
## Used directly for a list of already-formatted lines, and as the scrolling
## half of `nimtui/listview <listview.html>`_ and
## `nimtui/textarea <textarea.html>`_.

import std/[sequtils, math]
import ./style
export style

type
  Viewport* = object
    top*: int       ## index of the first visible line
    height*: int

proc clampTop*(v: var Viewport, total: int) =
  v.top = max(min(v.top, total - v.height), 0)

proc ensureVisible*(v: var Viewport, index, total: int) =
  ## Scroll the minimum amount needed to bring `index` into view.
  if v.height <= 0: return
  if index < v.top: v.top = index
  elif index >= v.top + v.height: v.top = index - v.height + 1
  v.clampTop total

proc scrollBy*(v: var Viewport, delta, total: int) =
  v.top += delta
  v.clampTop total

proc window*[T](v: Viewport, items: openArray[T]): seq[T] =
  ## The visible slice, never over-running the end of `items`.
  let last = min(v.top + v.height, items.len)
  if v.top < last: @items[v.top ..< last] else: @[]

proc pageUp*(v: var Viewport, total: int) =
  ## Scroll by one screen less a line, so a line of context carries over and the
  ## reader has something to anchor to.
  v.scrollBy(-max(v.height - 1, 1), total)

proc pageDown*(v: var Viewport, total: int) =
  v.scrollBy(max(v.height - 1, 1), total)

proc halfPageUp*(v: var Viewport, total: int) =
  v.scrollBy(-max(v.height div 2, 1), total)

proc halfPageDown*(v: var Viewport, total: int) =
  v.scrollBy(max(v.height div 2, 1), total)

proc toTop*(v: var Viewport) =
  v.top = 0

proc toBottom*(v: var Viewport, total: int) =
  ## Scroll so the last item is the last visible one — following a growing log.
  v.top = max(total - v.height, 0)

proc atTop*(v: Viewport): bool = v.top == 0

proc atBottom*(v: Viewport, total: int): bool =
  v.top + v.height >= total

proc scrollFraction*(v: Viewport, total: int): float =
  ## How far down the content the window sits, 0 to 1. Everything fitting on
  ## screen counts as 0 — there is nowhere to scroll to, so no other answer is
  ## meaningful.
  let scrollable = total - v.height
  if scrollable <= 0: 0.0 else: v.top.float / scrollable.float

proc scrollbar*(v: Viewport, total: int, track = " ", thumb = "┃"): seq[string] =
  ## One glyph per visible row, sized and positioned to reflect the window.
  ## Empty when everything fits.
  if v.height <= 0: return @[]
  if total <= v.height: return newSeqWith(v.height, " ")
  let size = max((v.height * v.height) div total, 1)
  let span = v.height - size
  let scrollable = total - v.height
  let start = if scrollable <= 0: 0
              else: ((v.top * span) div scrollable)
  for i in 0 ..< v.height:
    result.add(if i >= start and i < start + size: thumb else: track)

const EighthBlocks* = ["", "▁", "▂", "▃", "▄", "▅", "▆", "▇"]
  ## Filled from the bottom, indexed by eighths of a cell — `EighthBlocks[3]` is
  ## `▃`, three eighths. Index 0 is the empty string rather than `" "` so a
  ## caller can tell "nothing to draw" from "a blank cell" without comparing
  ## glyphs.
  ##
  ## There is no matching set filled from the *top*: `▔` is the only top-aligned
  ## block element and it is one eighth. That asymmetry is why
  ## `smoothScrollbar`_ reverses one of its two end cells instead of indexing a
  ## second table — see the note there.

proc smoothScrollbar*(v: Viewport, total: int, style = Style().faint(),
                      trackStyle = Style(), track = " ",
                      thumb = "█"): seq[string] =
  ## `scrollbar`_ with the thumb positioned and sized to an eighth of a cell.
  ##
  ## One styled cell per visible row, each exactly one column. Empty when
  ## `v.height` is zero, and all track when everything fits.
  ##
  ## Whole-cell resolution is coarser than it sounds. A ten-row window over a
  ## thousand lines has nine cells of travel for nine hundred and ninety lines of
  ## document, so the first ninety keypresses all draw the *same* picture and the
  ## scrollbar reads as broken. In eighths those ninety draw seven, which
  ## `tcomponents.nim` measures rather than asserting from the arithmetic.
  ##
  ## The two ends are drawn differently on purpose, and it is not symmetry that
  ## was overlooked. The top of the thumb needs a cell filled from the bottom,
  ## which is `EighthBlocks`_; the bottom of the thumb needs one filled from the
  ## top, which Unicode does not have. So that cell is the same glyph with
  ## foreground and background swapped — `reverse` is an attribute rather than a
  ## colour, so this survives `cpNoColor` intact, unlike the sub-cell trick in
  ## `widgets.gauge` which has to turn itself off there.
  ##
  ## `style` is the thumb's and `trackStyle` the gutter's; the partial cells take
  ## the thumb's foreground over the track's background, so a scrollbar with a
  ## track colour keeps it under the fractional ends.
  if v.height <= 0: return @[]
  let cells = v.height
  let trackCell = trackStyle.render(track)
  result = newSeqWith(cells, trackCell)
  if total <= cells: return

  let
    partial = trackStyle.merge(style)
    thumbCell = style.render(thumb)
    # Never less than a cell: a two-eighth sliver is accurate and unfindable.
    size = max(float(cells * cells) / float(total), 1.0)
    scrollable = float(total - cells)
    at = clamp(float(v.top) / scrollable, 0.0, 1.0)
    # Truncate the start and round the size up, so a thumb is never drawn
    # shorter than the fraction it stands for. Rounding both the same way
    # instead loses an eighth off one end at most positions, and at the bottom
    # of the document leaves the thumb short of the last row — which is read as
    # "there is a little more" and is the one thing a scrollbar must not say
    # wrongly.
    startEighth = int((float(cells) - size) * at * 8.0)
    endEighth = startEighth + int(ceil(size * 8.0))
    startCell = startEighth div 8
    endCell = endEighth div 8

  for i in startCell ..< min(endCell, cells):
    result[i] = thumbCell
  if startCell < cells:
    # `(8 - frac) mod 8`: a thumb starting `frac` eighths down the cell fills the
    # `8 - frac` below it, and a start exactly on the boundary fills the whole
    # cell, which the loop above already did.
    let g = EighthBlocks[(8 - startEighth mod 8) mod 8]
    if g.len > 0: result[startCell] = partial.render(g)
  if endCell < cells:
    let g = EighthBlocks[(8 - endEighth mod 8) mod 8]
    if g.len > 0: result[endCell] = partial.reverse().render(g)

proc withScrollbar*(v: Viewport, lines: sink seq[string], total: int,
                    style = Style().faint(), smooth = true): seq[string] =
  ## Append the scrollbar gutter to each already-padded line.
  ##
  ## `sink`, so a caller handing over rows it is finished with gets a move rather
  ## than a copy of every string in the seq — this runs once per frame.
  ##
  ## `smooth` picks `smoothScrollbar`_ over `scrollbar`_. It defaults to on
  ## because the whole-cell thumb is not a different look so much as a worse
  ## answer to the same question, and a gutter is not something an application
  ## chooses to opt into being accurate. Turn it off for a terminal or font
  ## without the block elements, which is the same reason `AsciiBorder` exists.
  let bar = if smooth: v.smoothScrollbar(total, style)
            else: v.scrollbar(total).mapIt(style.render(it))
  result = lines
  while result.len < v.height: result.add ""
  for i in 0 ..< result.len:
    result[i].add(if i < bar.len: bar[i] else: " ")
