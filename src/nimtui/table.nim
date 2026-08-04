## Tabular data with columns that line up.
##
## Lining up is the whole job, and it is why this cannot be done with
## `strutils.alignLeft`: a cell containing CJK text, an emoji or a colour escape
## has a byte length, a rune count and a column count that are all different,
## and only the column count moves the next column. Every measurement here goes
## through `displayWidth <ansi.html#displayWidth,string>`_, so styled and
## double-width cells sit in the same grid as plain ASCII ones.
##
## ```nim
## var t = table([column("service"),
##                column("reqs", align = aRight),
##                column("p99 ms", align = aRight)])
## t.add("api", "1204", "82.4")
## t.add("worker", "318", "140.1")
## echo t.render()
## ```
##
## Columns size themselves to their content unless given a fixed `width`. Pass a
## total width to `render` and the flexible columns are shrunk or stretched to
## hit it exactly, so a table can fill a pane whatever the terminal size.

import std/strutils
import ./[ansi, style, spans, layout]
export style, spans, layout

type
  Column* = object
    header*: string
    width*: int              ## fixed column width; 0 sizes to the content
    minWidth*: int           ## floor when shrinking to fit a total width
    align*, headerAlign*: Align
    style*, headerStyle*: Style

  Table* = object
    columns*: seq[Column]
    rows*: seq[seq[string]]
    borderChars*: Border
    borderStyle*: Style
    showBorder*: bool
    showHeader*: bool
    headerRule*: bool        ## a rule between the header and the body
    padding*: int            ## blank cells either side of every cell's content
    zebra*: Style            ## laid over alternate rows; empty turns it off
    rowStyles*: seq[Style]   ## per-row overrides, sparse — shorter than `rows` is fine

proc column*(header: string, width = 0, align = aLeft, headerAlign = aLeft,
             style = Style(), headerStyle = Style().bold(),
             minWidth = 3): Column =
  ## A column. `minWidth` defaults to 3 because that is the narrowest a shrunk
  ## column can be and still show a character and an ellipsis.
  Column(header: header, width: width, minWidth: max(minWidth, 1), align: align,
         headerAlign: headerAlign, style: style, headerStyle: headerStyle)

proc table*(columns: openArray[Column], border = RoundedBorder): Table =
  Table(columns: @columns, borderChars: border, showBorder: true,
        showHeader: true, headerRule: true, padding: 1,
        borderStyle: Style().faint())

proc add*(t: var Table, cells: varargs[string]) =
  ## Append a row. A row with the wrong number of cells is padded or ignored at
  ## render time rather than rejected here, so building a table from ragged data
  ## does not need a guard at every call site.
  t.rows.add @cells

proc cell(t: Table, row, col: int): string =
  if row < t.rows.len and col < t.rows[row].len: t.rows[row][col] else: ""

proc columnWidths*(t: Table, total = 0): seq[int] =
  ## The content width of each column, before padding and separators.
  ##
  ## Exposed because a caller sometimes needs to line something else up with the
  ## table — a chart under a column, or a second table sharing its grid.
  let n = t.columns.len
  if n == 0: return @[]
  result = newSeq[int](n)
  for i, c in t.columns:
    if c.width > 0:
      result[i] = c.width
    else:
      var w = if t.showHeader: displayWidth(c.header) else: 0
      for r in 0 ..< t.rows.len:
        w = max(w, displayWidth(t.cell(r, i)))
      result[i] = w
  if total <= 0: return

  # Chrome is everything that is not cell content: the outer frame, one
  # separator between each pair of columns, and the padding on both sides of
  # every cell.
  let chrome = (if t.showBorder: n + 1 else: 0) + n * 2 * t.padding
  let budget = total - chrome
  if budget <= 0: return

  var sum = 0
  for w in result: sum += w

  # The shrink floor is the column's `minWidth`, but never more than the width
  # it naturally wanted: a column holding one-character values has a natural
  # width of 1, and "cannot go below 3" must not be read as "must be 3" — that
  # would shrink the columns that actually hold something in order to widen one
  # that does not.
  var floors = newSeq[int](n)
  for i in 0 ..< n:
    floors[i] = min(result[i], t.columns[i].minWidth)

  if sum > budget:
    # Shrink the widest shrinkable column one cell at a time. O(excess * n),
    # which for terminal widths is a few thousand operations at worst, and it
    # distributes the loss far more evenly than a proportional pass followed by
    # a rounding fixup.
    #
    # Two passes: the first respects `minWidth`, and only if that cannot reach
    # the budget does the second ignore it and shrink towards one column each.
    # Overshooting the requested width is the worse failure — the renderer
    # assumes no line wrapping, so a table wider than its pane does not merely
    # look wrong, it desynchronises the frame.
    for respectFloors in [true, false]:
      while sum > budget:
        var pick = -1
        for i in 0 ..< n:
          let limit = if respectFloors: floors[i] else: 1
          if result[i] > limit and (pick < 0 or result[i] > result[pick]):
            pick = i
        if pick < 0: break          # everything is already at its floor
        dec result[pick]
        dec sum
  elif sum < budget:
    # Hand the surplus to the flexible columns, round-robin from the left so a
    # remainder that will not divide evenly does not all land on one column.
    var flexible: seq[int]
    for i, c in t.columns:
      if c.width == 0: flexible.add i
    if flexible.len > 0:
      var i = 0
      while sum < budget:
        inc result[flexible[i mod flexible.len]]
        inc sum
        inc i

proc rule(t: Table, widths: seq[int], left, mid, right: string): string =
  let
    h = t.borderChars.horizontal
    l = if left.len > 0: left else: h
    m = if mid.len > 0: mid else: h
    r = if right.len > 0: right else: h
  var s = l
  for i, w in widths:
    if i > 0: s.add m
    s.add h.repeat(w + 2 * t.padding)
  s.add r
  t.borderStyle.render(s)

proc renderRow(t: Table, widths: seq[int], cells: openArray[string],
               styles: openArray[Style], aligns: openArray[Align],
               rowStyle: Style): string =
  let
    gutter = spaces(t.padding)
    v = t.borderStyle.render(t.borderChars.vertical)
  var line: Spans
  for i, w in widths:
    if t.showBorder and i == 0: line.add v
    elif t.showBorder: line.add v
    # The padding carries the cell's own style, so a row background runs
    # unbroken between the separators instead of striping only behind the text.
    let st = styles[i].merge(rowStyle)
    if t.padding > 0: line.add(gutter, st)
    let text = if displayWidth(cells[i]) > w: elide(cells[i], w) else: cells[i]
    line.add(alignVisible(text, w, aligns[i]), st)
    if t.padding > 0: line.add(gutter, st)
  if t.showBorder: line.add v
  line.render()

proc render*(t: Table, width = 0): string =
  ## The table as a block. `width` of 0 sizes to the content; anything else is
  ## the exact total width, flexible columns absorbing the difference.
  ##
  ## A width too small even for one column per cell plus the frame is clipped
  ## rather than overflowed — at that size there is nothing useful to draw, and
  ## a line wider than its pane breaks the renderer's no-wrap assumption.
  let n = t.columns.len
  if n == 0: return ""
  let widths = t.columnWidths(width)

  var lines: seq[string]
  if t.showBorder:
    lines.add t.rule(widths, t.borderChars.topLeft, t.borderChars.teeDown,
                     t.borderChars.topRight)

  if t.showHeader:
    var
      headers = newSeq[string](n)
      styles = newSeq[Style](n)
      aligns = newSeq[Align](n)
    for i, c in t.columns:
      headers[i] = c.header
      styles[i] = c.headerStyle
      aligns[i] = c.headerAlign
    lines.add t.renderRow(widths, headers, styles, aligns, Style())
    if t.headerRule:
      lines.add t.rule(widths,
                       if t.showBorder: t.borderChars.teeRight else: "",
                       t.borderChars.cross,
                       if t.showBorder: t.borderChars.teeLeft else: "")

  var
    cells = newSeq[string](n)
    styles = newSeq[Style](n)
    aligns = newSeq[Align](n)
  for i, c in t.columns:
    styles[i] = c.style
    aligns[i] = c.align
  for r in 0 ..< t.rows.len:
    for i in 0 ..< n: cells[i] = t.cell(r, i)
    var rs = Style()
    if r < t.rowStyles.len and not t.rowStyles[r].isEmpty: rs = t.rowStyles[r]
    elif r mod 2 == 1: rs = t.zebra
    lines.add t.renderRow(widths, cells, styles, aligns, rs)

  if t.showBorder:
    lines.add t.rule(widths, t.borderChars.bottomLeft, t.borderChars.teeUp,
                     t.borderChars.bottomRight)
  if width > 0:
    for i in 0 .. lines.high:
      if displayWidth(lines[i]) > width:
        lines[i] = truncateVisible(lines[i], width)
  lines.join("\n")

proc totalWidth*(t: Table): int =
  ## The width the table renders at when no total is imposed.
  let n = t.columns.len
  if n == 0: return 0
  for w in t.columnWidths(): result += w + 2 * t.padding
  if t.showBorder: result += n + 1
