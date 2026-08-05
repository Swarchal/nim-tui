## Composing rectangular blocks of text: padding, joining, wrapping, bordered
## panels, and drawing one block over another.
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
## For anything beyond a title and a border, build a `Panel <#Panel>`_ once and
## render with it repeatedly — it carries the border, both labels, padding, fill
## and shadow as a value, in the same style as `Style <style.html#Style>`_:
##
## ```nim
## let pane = panel(ThickBorder).title("logs").footer("42 lines")
##                              .pad(1).shadow()
## echo pane.render(body, 40, 12)
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
import ./[ansi, style, spans]
# `renderBox` takes `Style` values, so a caller importing only this module still
# needs them — re-exported for the same reason `ansi` re-exports `width`.
# `spans` comes with it for `Align`, and because a styled line is the natural
# thing to hand to a block helper.
export style, spans

type
  Border* = object
    ## The pieces a frame is drawn from. Each is a string rather than a `char`
    ## so multi-byte glyphs work.
    ##
    ## The first six draw a panel. The five junctions after them are only needed
    ## where an interior rule meets the frame, which today means
    ## `nimtui/table <table.html>`_; a hand-written `Border` that leaves them
    ## empty still renders a correct panel, and a table falls back to
    ## `horizontal` for whichever junctions are missing.
    topLeft*, topRight*, bottomLeft*, bottomRight*, horizontal*, vertical*: string
    teeDown*, teeUp*, teeRight*, teeLeft*, cross*: string

const
  RoundedBorder* = Border(topLeft: "╭", topRight: "╮", bottomLeft: "╰",
                          bottomRight: "╯", horizontal: "─", vertical: "│",
                          teeDown: "┬", teeUp: "┴", teeRight: "├",
                          teeLeft: "┤", cross: "┼")
  SquareBorder* = Border(topLeft: "┌", topRight: "┐", bottomLeft: "└",
                         bottomRight: "┘", horizontal: "─", vertical: "│",
                         teeDown: "┬", teeUp: "┴", teeRight: "├",
                         teeLeft: "┤", cross: "┼")
  DoubleBorder* = Border(topLeft: "╔", topRight: "╗", bottomLeft: "╚",
                         bottomRight: "╝", horizontal: "═", vertical: "║",
                         teeDown: "╦", teeUp: "╩", teeRight: "╠",
                         teeLeft: "╣", cross: "╬")
  ThickBorder* = Border(topLeft: "┏", topRight: "┓", bottomLeft: "┗",
                        bottomRight: "┛", horizontal: "━", vertical: "┃",
                        teeDown: "┳", teeUp: "┻", teeRight: "┣",
                        teeLeft: "┫", cross: "╋")
    ## Heavy strokes. Pairs with a plain border on the panes that lack focus.
  DashedBorder* = Border(topLeft: "╭", topRight: "╮", bottomLeft: "╰",
                         bottomRight: "╯", horizontal: "┄", vertical: "┆",
                         teeDown: "┬", teeUp: "┴", teeRight: "├",
                         teeLeft: "┤", cross: "┼")
  AsciiBorder* = Border(topLeft: "+", topRight: "+", bottomLeft: "+",
                        bottomRight: "+", horizontal: "-", vertical: "|",
                        teeDown: "+", teeUp: "+", teeRight: "+",
                        teeLeft: "+", cross: "+")
    ## For terminals or fonts without box-drawing glyphs, and for captures that
    ## have to survive a plain-text pipe.
  HiddenBorder* = Border(topLeft: " ", topRight: " ", bottomLeft: " ",
                         bottomRight: " ", horizontal: " ", vertical: " ",
                         teeDown: " ", teeUp: " ", teeRight: " ",
                         teeLeft: " ", cross: " ")
    ## Occupies the same cells as any other border but draws nothing, so a panel
    ## can be given breathing room without a visible frame — and so a row of
    ## panes stays aligned when only some of them are framed.

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

proc alignVisible*(s: string, width: int, align: Align): string =
  ## Place `s` in a `width`-column field, truncating if it does not fit.
  case align
  of aLeft: padVisible(truncateVisible(s, width), width)
  of aCenter: centerVisible(s, width)
  of aRight:
    let w = displayWidth(s)
    if w >= width: truncateVisible(s, width) else: spaces(width - w) & s

# --- wrapping -----------------------------------------------------------------

proc wrapText*(s: string, width: int): seq[string] =
  ## Word-wrap to `width` columns, measured in columns rather than characters.
  ##
  ## Existing newlines are kept as hard breaks, including blank lines, so
  ## paragraph structure survives. A single word longer than the line is broken
  ## across lines rather than allowed to overflow — the renderer assumes no
  ## wrapping, so an over-long line is not merely ugly, it desynchronises the
  ## frame.
  ##
  ## Styled text wraps correctly (escape sequences take no columns), but a run
  ## broken across a line boundary carries its escapes forward via
  ## `sliceVisible`, so the colour continues rather than stopping at the break.
  if width <= 0: return @[]
  for para in s.split('\n'):
    var
      cur = ""
      curW = 0
      # Whether a separator space is owed before the next word. Splitting on ' '
      # means n words are rejoined with n-1 spaces, and *which* space is owed
      # cannot be inferred from `curW > 0`: that conflates "this is the start of
      # an output line" with "nothing has been added yet", which are different
      # for a line beginning with spaces. Using it dropped leading indentation
      # entirely — `wrapText("    x", 40)` came back as `"x"`, mangling every
      # indented line of code or quoted text even when nothing needed wrapping.
      pending = false
    for word in para.split(' '):
      let
        w = displayWidth(word)
        sep = if pending: 1 else: 0
      if curW > 0 and curW + sep + w > width:
        result.add cur
        cur.setLen 0
        curW = 0
        # A continuation line does not carry the separator that caused the break.
        pending = false
      if curW + (if pending: 1 else: 0) + w <= width:
        if pending:
          cur.add ' '
          inc curW
        cur.add word
        curW += w
      else:
        # Longer than a whole line: hard-break it. `cur` is empty here unless the
        # flush above did not fire, which happens only when the line was empty.
        if curW > 0:
          result.add cur
          cur.setLen 0
          curW = 0
        var
          rest = word
          restW = w
        while restW > width:
          result.add truncateVisible(rest, width)
          rest = sliceVisible(rest, width, restW - width)
          restW = displayWidth(rest)
        cur = rest
        curW = restW
      pending = true
    result.add cur       # a blank source line is a blank output line

# --- fills, shadows and overlays ----------------------------------------------

proc fillBlock*(s: string, style: Style, width = -1, height = -1): string =
  ## Square `s` off and apply `style` to every line — a background colour across
  ## the whole rectangle rather than only behind the text.
  ##
  ## Each line is styled separately, never the joined block, because the
  ## renderer erases to the end of each line it rewrites: a background left open
  ## across a newline is smeared to the right-hand edge of the screen.
  let lines = padBlockLines(s, width, height)
  if style.isEmpty: return lines.join("\n")
  var rows = newSeqOfCap[string](lines.len)
  for line in lines: rows.add style.render(line)
  rows.join("\n")

proc shadow*(s: string, style = Style().faint(), glyph = "░"): string =
  ## A drop shadow one cell right and one cell down.
  ##
  ## **This grows the block by one column and one row.** A shadowed panel in a
  ## fixed-size slot must therefore be rendered one smaller than the slot, or it
  ## pushes its neighbours over.
  let
    lines = padBlockLines(s)
    w = if lines.len > 0: displayWidth(lines[0]) else: 0
    cell = style.render(glyph)
  var rows = newSeqOfCap[string](lines.len + 1)
  for i, line in lines:
    # Nothing casts a shadow above its own top edge, so the first row gets a
    # space; without that the shadow reads as a misaligned second border.
    rows.add line & (if i == 0: " " else: cell)
  rows.add " " & style.render(glyph.repeat(w))
  rows.join("\n")

proc overlay*(base, top: string, x, y: int): string =
  ## Draw `top` over `base` at column `x`, row `y`, keeping `base`'s dimensions.
  ##
  ## The base is squared off first, and anything of `top` falling outside it is
  ## clipped, so the result is always exactly as large as `base` was — which is
  ## what makes this safe to use on a full-screen frame.
  ##
  ## Used for dialogs, popups and toasts: render the background view, render the
  ## dialog, and put one on the other.
  var lines = padBlockLines(base)
  if lines.len == 0: return base
  let bw = displayWidth(lines[0])
  # Bound to a `let` rather than iterated directly: in a for-loop `split`
  # resolves to the single-value iterator overload, not the seq-returning proc.
  let topLines = top.split('\n')
  for i in 0 ..< topLines.len:
    let row = y + i
    if row < 0 or row >= lines.len: continue
    # A negative x clips the left of the overlay rather than shifting it right.
    var
      tl = topLines[i]
      col = x
    if col < 0:
      tl = sliceVisible(tl, -col, max(bw, 0))
      col = 0
    if col >= bw: continue
    let clipped = truncateVisible(tl, bw - col)
    let tw = displayWidth(clipped)
    if tw == 0: continue
    let
      left = if col > 0: sliceVisible(lines[row], 0, col) else: ""
      used = col + tw
      right = if used < bw: sliceVisible(lines[row], used, bw - used) else: ""
    # A reset on each side of the overlay: the base's styling must not bleed
    # into it, and its own must not bleed back out. `sliceVisible` has already
    # put the base's escapes at the front of `right`, so the tail restyles
    # itself.
    lines[row] = left & Reset & clipped & Reset & right
  lines.join("\n")

proc place*(base, top: string, hAlign = aCenter, vAlign = aCenter): string =
  ## `overlay` with the position worked out from an alignment instead of
  ## coordinates — the usual way to put a dialog in the middle of a frame.
  let
    bw = blockWidth(base)
    bh = blockHeight(base)
    tw = blockWidth(top)
    th = blockHeight(top)
    x = case hAlign
        of aLeft: 0
        of aCenter: (bw - tw) div 2
        of aRight: bw - tw
    y = case vAlign
        of aLeft: 0                    # aLeft doubles as "top" on this axis
        of aCenter: (bh - th) div 2
        of aRight: bh - th
  overlay(base, top, max(x, 0), max(y, 0))

# --- panels -------------------------------------------------------------------

type
  Panel* = object
    ## A reusable panel description. Like `Style <style.html#Style>`_ it is a
    ## value whose setters return copies, so a panel can be declared once and
    ## specialised at the point of use:
    ##
    ## ```nim
    ## let base = panel().pad(1)
    ## echo base.title("left").render(a, 20, 8)
    ## echo base.title("right").border(ThickBorder).render(b, 20, 8)
    ## ```
    ##
    ## Fields carry the `-Chars`/`-Text` suffixes so the setters can have the
    ## short names, the same trick `Style` plays with `fgc` and `fg`.
    borderChars*: Border
    titleText*, footerText*: string
    titleAlignment*, footerAlignment*: Align
    borderStyle*, titleStyle*, footerStyle*, fillStyle*: Style
    padding*: int
    hasShadow*: bool
    shadowStyle*: Style

proc panel*(border = RoundedBorder): Panel =
  Panel(borderChars: border, titleAlignment: aLeft, footerAlignment: aRight,
        shadowStyle: Style().faint())

proc border*(p: Panel, b: Border): Panel =
  result = p
  result.borderChars = b

proc title*(p: Panel, text: string, align = aLeft): Panel =
  result = p
  result.titleText = text
  result.titleAlignment = align

proc footer*(p: Panel, text: string, align = aRight): Panel =
  ## A second label, drawn into the bottom border. Good for counts, positions
  ## and key hints that belong to one pane rather than to the whole screen.
  result = p
  result.footerText = text
  result.footerAlignment = align

proc styled*(p: Panel, border = Style(), title = Style(), footer = Style(),
             fill = Style()): Panel =
  result = p
  result.borderStyle = border
  result.titleStyle = title
  result.footerStyle = footer
  result.fillStyle = fill

proc pad*(p: Panel, n: int): Panel =
  ## Blank cells between the border and the content, on all four sides.
  result = p
  result.padding = max(n, 0)

proc shadow*(p: Panel, style = Style().faint()): Panel =
  ## Turn on the drop shadow. Remember it grows the rendered block by one column
  ## and one row — see `shadow <#shadow,string,Style,string>`_.
  result = p
  result.hasShadow = true
  result.shadowStyle = style

proc borderRow(p: Panel, left, right, label: string, labelStyle: Style,
               align: Align, inner: int): string =
  ## One horizontal edge, with a label let into it.
  ##
  ## Border runs are styled separately from the label rather than styling the
  ## whole row, so a reset inside the label cannot leak into the border colour.
  let h = p.borderChars.horizontal
  # The leading horizontal is part of the interior, so it only exists when there
  # is an interior. Emitting it unconditionally made the top row one column wider
  # than every other row of a panel with `width` of 2 or less.
  if label.len == 0 or inner <= 4:
    return p.borderStyle.render(left & h.repeat(inner) & right)
  let
    # Flattened before it is measured: a title or footer is often a filename or a
    # position read off something else, and a newline in one would put a line
    # break inside a border row — a box one row taller than the height asked for.
    t = " " & truncateVisible(oneLine(label), inner - 4) & " "
    tw = displayWidth(t)
    lead = case align
           of aLeft: 1
           of aCenter: (inner - tw) div 2
           of aRight: inner - tw - 1
    lo = clamp(lead, 0, inner - tw)
  result = p.borderStyle.render(left & h.repeat(lo))
  result.add labelStyle.render(t)
  result.add p.borderStyle.render(h.repeat(inner - tw - lo) & right)

proc render*(p: Panel, content: string, width, height: int): string =
  ## Draw `content` in a panel of exactly `width` x `height` cells — unless a
  ## shadow is on, which adds one of each.
  ##
  ## Two border rows and two border columns are the floor, so a `width` or
  ## `height` below 2 still comes back 2 wide or 2 tall — four corners and
  ## nothing between them.
  let
    inner = max(width - 2, 0)
    interior = max(height - 2, 0)
    # Padding never eats into the frame: it is capped at what the interior can
    # give up, so an over-padded small panel comes back the size asked for
    # instead of overflowing it.
    hpad = min(p.padding, inner div 2)
    vpad = min(p.padding, interior div 2)
    innerW = max(inner - 2 * hpad, 0)
    innerH = max(interior - 2 * vpad, 0)
    body = padBlockLines(content, innerW, innerH)
    v = p.borderStyle.render(p.borderChars.vertical)
    gutter = spaces(hpad)
    blank = spaces(inner)

  let top = p.borderRow(p.borderChars.topLeft, p.borderChars.topRight,
                        p.titleText, p.titleStyle, p.titleAlignment, inner)
  let bottom = p.borderRow(p.borderChars.bottomLeft, p.borderChars.bottomRight,
                           p.footerText, p.footerStyle, p.footerAlignment, inner)

  var bytes = top.len + bottom.len + 2
  for line in body: bytes += line.len + 2 * (v.len + hpad) + 1
  var res = newStringOfCap(bytes)
  res.add top

  template row(cells: string) =
    res.add '\n'
    res.add v
    res.add(if p.fillStyle.isEmpty: cells else: p.fillStyle.render(cells))
    res.add v

  for _ in 0 ..< vpad: row(blank)
  for line in body: row(gutter & line & gutter)
  for _ in 0 ..< vpad: row(blank)
  res.add '\n'
  res.add bottom

  if p.hasShadow: shadow(res, p.shadowStyle) else: res

proc renderBox*(content: string, width, height: int, title = "",
                border = RoundedBorder, borderStyle = Style(),
                titleStyle = Style(), titleAlign = aLeft, footer = "",
                footerStyle = Style(), footerAlign = aRight,
                padding = 0, fill = Style()): string =
  ## A bordered panel of exactly `width` x `height` cells, content clipped to fit.
  ##
  ## The one-shot form of `Panel <#Panel>`_: fine for a panel drawn in one place,
  ## whereas a panel drawn in several wants to be built once and reused.
  ##
  ## A `title` is drawn into the top border when there is room, and a `footer`
  ## into the bottom border on the same terms.
  var p = panel(border)
  p.titleText = title
  p.titleAlignment = titleAlign
  p.footerText = footer
  p.footerAlignment = footerAlign
  p.borderStyle = borderStyle
  p.titleStyle = titleStyle
  p.footerStyle = footerStyle
  p.fillStyle = fill
  p.padding = max(padding, 0)
  p.render(content, width, height)
