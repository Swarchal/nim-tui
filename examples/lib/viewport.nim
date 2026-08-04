## Scrolling window over a list of lines, plus a scrollbar gutter.

import std/[sequtils]
import nimtui

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

proc atTop*(v: Viewport): bool = v.top == 0

proc atBottom*(v: Viewport, total: int): bool =
  v.top + v.height >= total

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
