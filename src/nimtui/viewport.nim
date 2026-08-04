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

import std/sequtils
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

proc withScrollbar*(v: Viewport, lines: sink seq[string], total: int,
                    style = Style().faint()): seq[string] =
  ## Append the scrollbar gutter to each already-padded line.
  ##
  ## `sink`, so a caller handing over rows it is finished with gets a move rather
  ## than a copy of every string in the seq — this runs once per frame.
  let bar = v.scrollbar(total)
  result = lines
  while result.len < v.height: result.add ""
  for i in 0 ..< result.len:
    result[i].add style.render(if i < bar.len: bar[i] else: " ")
