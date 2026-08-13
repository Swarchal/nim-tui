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
##
## How much of the grid is *drawn* is four switches, and between them they cover
## the looks a table is usually asked for:
##
## ```nim
## t.showBorder = false     # the outer frame
## t.columnRules = false    # the vertical rules between columns
## t.rowRule = true         # a horizontal rule between every pair of rows
## t.headerWeight = lwHeavy # the rule under the header, heavier than the rest
## ```
##
## The frame and the column rules are deliberately *two* switches. Turning both
## off is the quiet look that suits dense data — no verticals at all, one rule
## under the header, which is where the eye needs it:
##
## ```text
##  service      reqs     p99   status
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━      t.showBorder = false
##  api-gateway  128,986  80.0    ok         t.columnRules = false
##  auth          41,652  66.3    ok         t.headerWeight = lwHeavy
## ```
##
## `headerWeight` computes its junctions rather than swapping a glyph, so a heavy
## rule inside a thin frame is `┝━━━┿━━━┥` and not `├━━━┼━━━┤`. It is
## `boxdraw <boxdraw.html>`_ doing the work, so every pairing of thin, heavy and
## double is available; a border with no line weight to meet — half blocks, `+`,
## spaces — keeps its own rule, since the border was chosen for that frame and
## the algebra was not.
##
## Which border to draw them *with* is a separate question, and
## `ruledBorder <layout.html#ruledBorder,LineWeight,LineWeight>`_ answers it for
## a frame heavier than its rules.

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
    showBorder*: bool        ## the outer frame
    columnRules*: bool       ## the vertical rules *between* columns
    showHeader*: bool
    headerRule*: bool        ## a rule between the header and the body
    headerWeight*: LineWeight
      ## the weight of that rule, `lwNone` to use the border's own interior one
    rowRule*: bool           ## a rule between every pair of body rows
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
        columnRules: true, showHeader: true, headerRule: true, padding: 1,
        borderStyle: Style().faint())

proc add*(t: var Table, cells: varargs[string]) =
  ## Append a row. A row with the wrong number of cells is padded or ignored at
  ## render time rather than rejected here, so building a table from ragged data
  ## does not need a guard at every call site.
  t.rows.add @cells

proc cell(t: Table, row, col: int): string =
  ## The cell's content, flattened onto one line.
  ##
  ## Every read of a cell goes through here — `columnWidths` to size the column
  ## and `render` to draw it — which is what makes this the place to flatten. A
  ## cell holding a newline is measured by `displayWidth` as nothing and drawn by
  ## the terminal as a line break, so the table returns more lines than it has
  ## rows and everything below it in the frame lands a row late. Log messages and
  ## exception text are the normal contents of a table cell and neither is under
  ## the caller's control.
  ##
  ## Here rather than in `add`, so that a caller who writes to `rows` directly —
  ## a public field, and the cheap way to reuse a table across frames — gets the
  ## same guarantee. And before measuring, never after: see `oneLine
  ## <ansi.html#oneLine,string>`_.
  if row < t.rows.len and col < t.rows[row].len: oneLine(t.rows[row][col]) else: ""

proc headerText(c: Column): string =
  ## The header, flattened — `cell`'s reason, for the row above the rows. Not
  ## named `header`, which is the field it reads.
  oneLine(c.header)

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
      var w = if t.showHeader: displayWidth(c.headerText) else: 0
      for r in 0 ..< t.rows.len:
        w = max(w, displayWidth(t.cell(r, i)))
      result[i] = w
  if total <= 0: return

  # Chrome is everything that is not cell content: the two frame columns, one
  # separator between each pair of columns, and the padding on both sides of
  # every cell. The frame and the separators are counted apart because they are
  # switched apart — a table can have either, both or neither.
  let chrome = (if t.showBorder: 2 else: 0) +
               (if t.columnRules: n - 1 else: 0) +
               n * 2 * t.padding
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

proc rule(t: Table, widths: seq[int], left, mid, right: string,
          edge = ""): string =
  ## One horizontal rule. `edge` is the glyph it is drawn with, defaulting to the
  ## border's interior rule — the top and bottom rules pass their own, since a
  ## half-block frame does not use the same glyph above and below, and what is
  ## left defaulting is the header rule, which is interior by definition.
  # A rule lines up with the row above it, so a junction is drawn exactly where
  # that row has a separator and nowhere else. Both switches are read here rather
  # than at the call site, so a third caller cannot get it wrong: emitting an end
  # where there is no frame, or a `┼` where there is no `│` to cross, is not a
  # stray glyph but a rule wider than every other line in the table — and nothing
  # pads a block to its *narrowest* line, so the whole thing then lays out at the
  # rule's width.
  let h = if edge.len > 0: edge else: t.borderChars.innerHorizontalEdge
  var s = ""
  if t.showBorder: s.add(if left.len > 0: left else: h)
  for i, w in widths:
    if i > 0 and t.columnRules: s.add(if mid.len > 0: mid else: h)
    s.add h.repeat(w + 2 * t.padding)
  if t.showBorder: s.add(if right.len > 0: right else: h)
  t.borderStyle.render(s)

proc interiorRule(t: Table, widths: seq[int]): string =
  ## A rule across the table at the border's own interior weight — the header
  ## rule's default, and every row rule.
  t.rule(widths,
         if t.showBorder: t.borderChars.teeRight else: "",
         t.borderChars.cross,
         if t.showBorder: t.borderChars.teeLeft else: "")

proc headerRuleLine(t: Table, widths: seq[int]): string =
  ## The rule under the header, at `headerWeight` when one is asked for.
  ##
  ## The three junctions are *computed* rather than taken from the border, which
  ## is what makes this more than a glyph swap: a heavier rule meeting a thin
  ## frame is `┝ ┿ ┥`, and those exist for every pairing `boxdraw` can express.
  ## Setting `innerHorizontal` heavy instead gets the run right and leaves the
  ## junctions thin, which is the mismatch this is here to avoid.
  if t.headerWeight == lwNone: return t.interiorRule(widths)
  let
    frameL = lineWeightOf(t.borderChars.leftEdge)
    frameR = lineWeightOf(t.borderChars.rightEdge)
    column = lineWeightOf(t.borderChars.innerVerticalEdge)
  # A border whose sides are half blocks, `+` or spaces has no arm weight to
  # meet, so there is no junction to compute and the border's own glyph is the
  # better answer — it was chosen for that frame and the algebra was not. Only
  # the parts actually drawn are required to be lines: a borderless table needs
  # nothing of the frame, and one without column rules nothing of the separator.
  if (t.showBorder and (frameL == lwNone or frameR == lwNone)) or
     (t.columnRules and column == lwNone):
    return t.interiorRule(widths)
  let w = t.headerWeight
  t.rule(widths,
         boxChar(top = frameL, bottom = frameL, right = w),
         boxChar(top = column, bottom = column, left = w, right = w),
         boxChar(top = frameR, bottom = frameR, left = w),
         boxChar(left = w, right = w))

proc renderRow(t: Table, widths: seq[int], cells: openArray[string],
               styles: openArray[Style], aligns: openArray[Align],
               rowStyle: Style): string =
  let
    gutter = spaces(t.padding)
    # The column separators are interior rules, not frame; `leftEdge` and
    # `rightEdge` below are the frame. On every border where the two are the same
    # glyph this is the distinction that costs nothing and reads as pedantry —
    # `ruledBorder(lwDouble, lwThin)` is the one where it is the whole point.
    v = t.borderStyle.render(t.borderChars.innerVerticalEdge)
    vLeft = t.borderStyle.render(t.borderChars.leftEdge)
    vRight = t.borderStyle.render(t.borderChars.rightEdge)
  var line: Spans
  for i, w in widths:
    # The frame and the column separators are three different glyphs on a border
    # whose sides differ; on every other border they are the same one. They are
    # also two different switches, so this is two conditions and not one.
    if i == 0:
      if t.showBorder: line.add vLeft
    elif t.columnRules: line.add v
    # The padding carries the cell's own style, so a row background runs
    # unbroken between the separators instead of striping only behind the text.
    let st = styles[i].merge(rowStyle)
    if t.padding > 0: line.add(gutter, st)
    let text = if displayWidth(cells[i]) > w: elide(cells[i], w) else: cells[i]
    line.add(alignVisible(text, w, aligns[i]), st)
    if t.padding > 0: line.add(gutter, st)
  if t.showBorder: line.add vRight
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
                     t.borderChars.topRight, t.borderChars.topEdge)

  if t.showHeader:
    var
      headers = newSeq[string](n)
      styles = newSeq[Style](n)
      aligns = newSeq[Align](n)
    for i, c in t.columns:
      headers[i] = c.headerText
      styles[i] = c.headerStyle
      aligns[i] = c.headerAlign
    lines.add t.renderRow(widths, headers, styles, aligns, Style())
    if t.headerRule:
      lines.add t.headerRuleLine(widths)

  var
    cells = newSeq[string](n)
    styles = newSeq[Style](n)
    aligns = newSeq[Align](n)
  for i, c in t.columns:
    styles[i] = c.style
    aligns[i] = c.align
  for r in 0 ..< t.rows.len:
    # Between rows, never above the first or below the last: those two are the
    # header rule and the frame's own bottom, and a table that draws its own
    # there has two rules where it means one.
    if t.rowRule and r > 0: lines.add t.interiorRule(widths)
    for i in 0 ..< n: cells[i] = t.cell(r, i)
    var rs = Style()
    if r < t.rowStyles.len and not t.rowStyles[r].isEmpty: rs = t.rowStyles[r]
    elif r mod 2 == 1: rs = t.zebra
    lines.add t.renderRow(widths, cells, styles, aligns, rs)

  if t.showBorder:
    lines.add t.rule(widths, t.borderChars.bottomLeft, t.borderChars.teeUp,
                     t.borderChars.bottomRight, t.borderChars.bottomEdge)
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
  if t.showBorder: result += 2
  if t.columnRules: result += n - 1
