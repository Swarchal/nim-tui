## Composing rectangular blocks of text: padding, joining, and bordered panels.
##
## A block is a plain string whose lines are separated by `\n` — the same thing
## `view` returns — so blocks compose with each other and with hand-written text
## without conversion. Nothing here holds a cell buffer or touches a terminal.
##
## ```nim
## let left = renderBox("cpu\n42%", 20, 6, title = "host")
## let right = renderBox("mem\n1.2G", 20, 6, title = "host")
## echo joinVertical(joinHorizontal([left, right], gap = 1), " q to quit")
## ```
##
## Every measurement goes through `displayWidth
## <ansi.html#displayWidth,string>`_, so styled and double-width text lays out
## correctly: escape sequences take no columns, CJK and emoji take two.
##
## Because a block is only a string, each helper measures the block it is given.
## Composing deeply therefore re-measures inner blocks — `renderBox` measures its
## content, then `joinHorizontal` measures the finished panel again. That is the
## price of blocks being ordinary strings; it is a few tens of microseconds for a
## screenful, well inside a frame.

import std/strutils
import ./[ansi, style]
# `renderBox` takes `Style` values, so a caller importing only this module still
# needs them — re-exported for the same reason `ansi` re-exports `width`.
export style

type
  Border* = object
    ## The six pieces `renderBox` draws a panel from. Each is a string rather
    ## than a `char` so multi-byte glyphs work.
    topLeft*, topRight*, bottomLeft*, bottomRight*, horizontal*, vertical*: string

const
  RoundedBorder* = Border(topLeft: "╭", topRight: "╮", bottomLeft: "╰",
                          bottomRight: "╯", horizontal: "─", vertical: "│")
  SquareBorder* = Border(topLeft: "┌", topRight: "┐", bottomLeft: "└",
                         bottomRight: "┘", horizontal: "─", vertical: "│")
  DoubleBorder* = Border(topLeft: "╔", topRight: "╗", bottomLeft: "╚",
                         bottomRight: "╝", horizontal: "═", vertical: "║")

proc blockWidth*(s: string): int =
  ## Visible width of the widest line.
  for line in s.split('\n'):
    result = max(result, displayWidth(line))

proc blockHeight*(s: string): int =
  ## Number of lines. A block always has at least one.
  s.count('\n') + 1

proc padBlockLines*(s: string, width = -1, height = -1): seq[string] =
  ## `padBlock` as lines. Callers that want lines should use this — going via
  ## `padBlock` joins them into one string that the caller then splits straight
  ## back, which copies every line twice for nothing.
  ##
  ## Each line is measured once, and a line already exactly `width` columns wide
  ## is returned untouched. That case is worth the check because it is the common
  ## one: every block out of `renderBox`, or out of a previous `padBlock`, is
  ## already rectangular, and the obvious spelling —
  ## `padVisible(truncateVisible(line, w), w)` — walks such a line twice and
  ## copies it once to arrive back at the line it started with.
  result = s.split('\n')
  var widths = newSeq[int](result.len)
  for i, line in result:
    widths[i] = displayWidth(line)
  var w = width
  if w < 0:
    for x in widths: w = max(w, x)
    w = max(w, 0)
  for i in 0 .. result.high:
    if widths[i] > w:
      result[i] = truncateVisible(result[i], w)
    elif widths[i] < w:
      result[i].add spaces(w - widths[i])   # in place: no second string
  if height >= 0:
    if result.len > height:
      result.setLen height
    else:
      let blank = spaces(w)
      while result.len < height: result.add blank

proc padBlock*(s: string, width = -1, height = -1): string =
  ## Force `s` into an exact rectangle. A negative axis is left alone, so
  ## `padBlock(s, 20)` squares the width and keeps however many lines there were.
  padBlockLines(s, width, height).join("\n")

proc joinHorizontal*(blocks: openArray[string], gap = 0): string =
  ## Place blocks side by side, each padded to its own width and to the tallest.
  if blocks.len == 0: return ""
  # `padBlockLines` measures each block's own width, so there is no separate
  # `blockWidth` pass, and the rows go straight into one buffer rather than a seq
  # that then has to be joined.
  var cols = newSeq[seq[string]](blocks.len)
  var height = 0
  for b in blocks: height = max(height, blockHeight(b))
  var bytes = 0
  for i, b in blocks:
    cols[i] = padBlockLines(b, -1, height)
    for line in cols[i]: bytes += line.len
  let sep = spaces(gap)
  result = newStringOfCap(bytes + height * (1 + gap * (blocks.len - 1)))
  for row in 0 ..< height:
    if row > 0: result.add '\n'
    for i in 0 ..< cols.len:
      if i > 0 and gap > 0: result.add sep
      result.add cols[i][row]

proc joinVertical*(blocks: varargs[string]): string =
  ## Stack blocks. Widths are left as they are; pad first if they must align.
  blocks.join("\n")

proc elide*(s: string, width: int, ellipsis = "…"): string =
  ## Truncate with a marker, so a cut string is distinguishable from a short one.
  ## Exact: the result is never wider than `width`, even when the cut would land
  ## inside a double-width rune.
  if width <= 0: return ""
  if displayWidth(s) <= width: return s
  let keep = width - displayWidth(ellipsis)
  if keep <= 0: return truncateVisible(ellipsis, width)
  truncateVisible(s, keep) & ellipsis

proc centerVisible*(s: string, width: int): string =
  ## Centre `s` in `width` columns, truncating instead if it does not fit. An odd
  ## remainder goes on the right.
  let w = displayWidth(s)
  if w >= width: return truncateVisible(s, width)
  let left = (width - w) div 2
  result = newStringOfCap(s.len + width - w)
  result.add spaces(left)
  result.add s
  result.add spaces(width - w - left)

proc renderBox*(content: string, width, height: int, title = "",
                border = RoundedBorder, borderStyle = Style(),
                titleStyle = Style()): string =
  ## A bordered panel of exactly `width` x `height` cells, content clipped to fit.
  ##
  ## Two border rows and two border columns are the floor, so a `width` or
  ## `height` below 2 still comes back 2 wide or 2 tall — four corners and nothing
  ## between them. A `title` is drawn into the top border when there is room.
  ##
  ## Border runs are styled individually rather than styling the whole line, so
  ## a reset inside the title cannot leak into the border colour.
  let inner = max(width - 2, 0)
  let body = padBlockLines(content, inner, max(height - 2, 0))
  let v = borderStyle.render(border.vertical)

  # The leading horizontal is part of the interior, so it only exists when there
  # is an interior. Emitting it unconditionally made the top row one column wider
  # than every other row of a panel with `width` of 2 or less.
  var top = borderStyle.render(border.topLeft &
                               (if inner > 0: border.horizontal else: ""))
  var used = if inner > 0: 1 else: 0
  if title.len > 0 and inner > 4:
    let t = " " & truncateVisible(title, inner - 4) & " "
    top.add titleStyle.render(t)
    used += displayWidth(t)
  top.add borderStyle.render(border.horizontal.repeat(max(inner - used, 0)) &
                             border.topRight)
  let bottom = borderStyle.render(border.bottomLeft &
    border.horizontal.repeat(inner) & border.bottomRight)

  var bytes = top.len + bottom.len + 2
  for line in body: bytes += line.len + 2 * v.len + 1
  result = newStringOfCap(bytes)
  result.add top
  for line in body:
    result.add '\n'
    result.add v
    result.add line
    result.add v
  result.add '\n'
  result.add bottom
