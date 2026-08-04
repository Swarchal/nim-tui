## Drawing with the mouse: press, drag, release, wheel.
##
## What this example is really about: `poMouseAllMotion` and the one thing that
## surprises everybody the first time they handle a drag.
##
## **Motion events are sampled, not continuous.** The terminal reports where the
## pointer *is* every so often, not every cell it crossed. Move quickly and two
## consecutive reports are ten cells apart, so painting only the reported cell
## draws a dotted line with gaps that get wider the faster you move. The fix is
## to interpolate from the previous point to this one — `stroke` below — which
## is why the model remembers `last`.
##
## The other fiddly part is coordinates. `MouseMsg.x`/`y` are 1-based *screen*
## cells, so turning one into a canvas cell means subtracting wherever the
## canvas starts, and that offset has to be derived from the same layout the
## view draws. `CanvasTop`/`CanvasLeft` below are that offset in one place; two
## copies of it drifting apart is how a paint program ends up drawing one row
## above the cursor.
##
##   nim c -r --path:src examples/paint.nim

import std/[strutils, strformat]
import nimtui

const
  Swatches = 12          ## colours sampled from the current gradient
  SwatchWidth = 4        ## columns per swatch in the palette strip
  PaletteRow = 2         ## 1-based screen row the palette is drawn on
  CanvasTop = 4          ## 1-based screen row of the canvas's first cell
  CanvasLeft = 2         ## 1-based screen column of the canvas's first cell
  Empty = -1

type
  Model = object
    cells: seq[seq[int]]      ## palette index per cell, `Empty` for none
    palette: seq[Color]
    gradients: seq[Gradient]
    gradientIdx: int
    current: int
    brush: int                ## radius + 1, so 1 is a single cell
    drawing, erasing: bool
    last: tuple[x, y: int]
    width, height: int
    theme: Theme
    status: string

proc canvasWidth(m: Model): int = max(m.width - 2, 1)
proc canvasHeight(m: Model): int = max(m.height - 5, 1)

proc resize(m: var Model) =
  ## Keep whatever has been drawn: growing adds empty cells, shrinking drops the
  ## ones that fell outside. Reallocating from scratch would clear the canvas on
  ## every terminal resize, which is a rude way to lose a drawing.
  let (w, h) = (m.canvasWidth, m.canvasHeight)
  m.cells.setLen h
  for row in m.cells.mitems:
    let old = row.len
    row.setLen w
    for i in old ..< w: row[i] = Empty

proc reshade(m: var Model) =
  m.palette = m.gradients[m.gradientIdx].ramp(Swatches)

proc clear(m: var Model) =
  for row in m.cells.mitems:
    for c in row.mitems: c = Empty

proc paint(m: var Model, cx, cy: int) =
  let r = m.brush - 1
  for y in cy - r .. cy + r:
    for x in cx - r .. cx + r:
      if y >= 0 and y < m.cells.len and x >= 0 and x < m.cells[y].len:
        m.cells[y][x] = if m.erasing: Empty else: m.current

proc stroke(m: var Model, x0, y0, x1, y1: int) =
  ## Paint every cell on the segment from the last reported point to this one.
  ##
  ## Without this a fast drag leaves a dotted line: the terminal samples the
  ## pointer, it does not trace it.
  let steps = max(abs(x1 - x0), abs(y1 - y0))
  if steps == 0:
    m.paint(x1, y1)
    return
  for i in 0 .. steps:
    m.paint(x0 + (x1 - x0) * i div steps, y0 + (y1 - y0) * i div steps)

# --- update -------------------------------------------------------------------

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of WindowSizeMsg:
    result[0].width = WindowSizeMsg(msg).width
    result[0].height = WindowSizeMsg(msg).height
    result[0].resize()

  elif msg of MouseMsg:
    let e = MouseMsg(msg)

    # The palette strip is a row of clickable swatches, so a press there picks a
    # colour rather than reaching the canvas at all.
    if e.y == PaletteRow and e.action == maPress and e.button == mbLeft:
      let idx = (e.x - 1) div SwatchWidth
      if idx >= 0 and idx < m.palette.len:
        result[0].current = idx
        result[0].status = &"colour {idx + 1}"
      return

    let
      cx = e.x - CanvasLeft
      cy = e.y - CanvasTop
    let inside = cx >= 0 and cy >= 0 and cy < m.cells.len and cx < m.canvasWidth

    case e.action
    of maPress:
      case e.button
      of mbLeft, mbRight:
        if inside:
          result[0].erasing = e.button == mbRight
          result[0].drawing = true
          result[0].last = (cx, cy)
          result[0].paint(cx, cy)
      of mbWheelUp: result[0].brush = min(m.brush + 1, 6)
      of mbWheelDown: result[0].brush = max(m.brush - 1, 1)
      else: discard
    of maMotion:
      # Motion arrives whether or not a button is down, so the drag flag is what
      # separates painting from merely moving the pointer across the canvas.
      if m.drawing and inside:
        result[0].stroke(m.last.x, m.last.y, cx, cy)
        result[0].last = (cx, cy)
    of maRelease:
      result[0].drawing = false
      result[0].erasing = false

  elif msg of KeyMsg:
    case $KeyMsg(msg)
    of "q", "ctrl+c": result[1] = quitCmd()
    of "c":
      result[0].clear()
      result[0].status = "cleared"
    of "g":
      result[0].gradientIdx = (m.gradientIdx + 1) mod m.gradients.len
      result[0].reshade()
      result[0].status = "palette " & $(result[0].gradientIdx + 1)
    of "[":
      result[0].brush = max(m.brush - 1, 1)
      result[0].status = &"brush {result[0].brush}"
    of "]":
      result[0].brush = min(m.brush + 1, 6)
      result[0].status = &"brush {result[0].brush}"
    else:
      let k = $KeyMsg(msg)
      if k.len == 1 and k[0] in '1' .. '9':
        let idx = k[0].ord - '1'.ord
        if idx < m.palette.len:
          result[0].current = idx
          result[0].status = &"colour {idx + 1}"

# --- view ---------------------------------------------------------------------

proc paletteStrip(m: Model): string =
  var line: Spans
  for i, c in m.palette:
    # The marker sits *on* the swatch, so it needs a foreground that survives
    # whatever colour landed underneath it — which is what `textOn` is for.
    let label = if i == m.current: centerVisible("◆", SwatchWidth)
                else: spaces(SwatchWidth)
    line.add(label, Style().bg(c).fg(textOn(c)))
  line.add("  " & m.theme.mutedStyle.render(&"brush {m.brush}  "))
  line.render()

proc canvasBlock(m: Model): string =
  ## Each row is built as `Spans`, which is what makes this cheap: a stroke of
  ## twenty cells in one colour is twenty runs sharing a style, and `render`
  ## coalesces them into a single escape pair rather than twenty.
  let faint = m.theme.mutedStyle
  var rows = newSeqOfCap[string](m.cells.len)
  for row in m.cells:
    var line: Spans
    for idx in row:
      # An empty cell is a faint dot rather than a space, so the canvas extent is
      # visible and a dark stroke is distinguishable from nothing at all.
      if idx == Empty: line.add("·", faint)
      else: line.add(" ", Style().bg(m.palette[idx]))
    rows.add line.render()
  rows.join("\n")

proc view(m: Model): string =
  if m.width == 0 or m.cells.len == 0: return "loading…"
  let
    t = m.theme
    w = m.width

  let header = statusBar(
    " " & gradientText("paint", m.gradients[m.gradientIdx], Style().bold()) &
      t.mutedStyle.render("  drag to draw · right-drag to erase"),
    "",
    t.mutedStyle.render(&"{m.canvasWidth}x{m.canvasHeight} "), w)

  let canvas = panel(RoundedBorder)
    .styled(border = t.borderStyle)
    .render(m.canvasBlock, w, m.canvasHeight + 2)

  let footer = statusBar(
    " " & hints({"click": "pick", "wheel": "brush", "1-9": "colour",
                 "g": "palette", "c": "clear", "q": "quit"}),
    "", t.warnStyle.render(m.status & " "), w)

  joinVertical(header, m.paletteStrip, canvas, footer)

when isMainModule:
  var model = Model(theme: NeonTheme, current: 0, brush: 1)
  model.gradients = @[RainbowGradient, SunsetGradient, CoolGradient,
                      HeatGradient, MonoGradient]
  model.reshade()
  discard newProgram(model, update, view,
                     # All-motion, not cell-motion: a drag has to be tracked
                     # even between button events for `stroke` to have anything
                     # to interpolate.
                     options = {poAltScreen, poHideCursor, poMouseAllMotion}).run()
