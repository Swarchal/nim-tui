## What perceptual mixing and a half-block cell each buy — the same ramp drawn
## every way, so the difference is on one screen rather than in a changelog.
##
## Two independent things, both about getting more colour out of the same cells:
##
## * **Which colours a ramp passes through.** `lerp` mixes in Oklab, so the
##   midpoint of blue and yellow is a blue-green. Mixing the bytes instead —
##   `msSrgb`, and what every naive implementation does — draws a straight line
##   between two corners of a cube whose axes are not perceptual, and the middle
##   of that line is `#808080`. The top panel draws both, one above the other.
## * **How many colours fit in a row.** A cell can carry two: `▌` puts one in the
##   foreground and the next in the *cell background*, which is what the gradient
##   `gauge` does. `h` turns it off, and the narrow bars are where it shows —
##   eight columns holding sixteen colours against eight.
##
## The third panel is every `Border` the library has, led by the six that divide
## a cell. The half-block pair's ink faces outward (`outer`) or inward (`inner`)
## so a panel reads as a slab rather than as a wire frame; `even` is the solid
## block trimmed to half a cell top and bottom, which is what makes its four
## sides look the same thickness on a grid whose cells are twice as tall as they
## are wide. The two hairlines are the far end of the same scale — a full cell
## of layout for an eighth of a cell of ink, which is the only way to quieten a
## pane without moving it.
##
## No timer and no state worth the name: this is a picture, and the keys only
## change how it is drawn.
##
##   nim c -r --path:src examples/palette.nim

import std/[strutils, strformat]
import nimtui

const
  Themes = [DefaultTheme, NeonTheme, SolarTheme, MonoTheme]
  ThemeNames = ["default", "neon", "solar", "mono"]
  Pairs = [("blue → yellow", hex"#0000ff", hex"#ffff00"),
           ("red → cyan", hex"#ff0000", hex"#00ffff"),
           ("violet → lime", hex"#7b2ff7", hex"#a3ff12"),
           ("black → white", hex"#000000", hex"#ffffff")]
  # The sub-cell borders first: this example exists for them, and a gallery that
  # drops its last row on a short terminal must not drop the point. The four
  # block ones lead, then the two hairlines — which are the same idea taken to
  # the other extreme, a whole cell of layout and an eighth of a cell of ink.
  Borders = [("outer", OuterHalfBlockBorder), ("inner", InnerHalfBlockBorder),
             ("block", BlockBorder), ("even", EvenBlockBorder),
             ("hair ─", HairlineHorizontalBorder),
             ("hair │", HairlineVerticalBorder),
             ("rounded", RoundedBorder),
             ("square", SquareBorder), ("double", DoubleBorder),
             ("thick", ThickBorder), ("dashed", DashedBorder),
             ("hv dash", HeavyDashedBorder),
             ("ascii", AsciiBorder), ("hidden", HiddenBorder)]
  BoxW = 13                    ## wide enough for the longest label plus a space
  BoxH = 3                     ## two border rows and one of interior

type Model = object
  half: bool
  themeIndex: int
  size: TermSize

proc theme(m: Model): Theme = Themes[m.themeIndex]

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)
  if msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("h", "space"): result[0].half = not m.half
    elif k.matches("t"): result[0].themeIndex = (m.themeIndex + 1) mod Themes.len

# --- drawing ------------------------------------------------------------------

proc bar(m: Model, a, b: Color, width: int, space: MixSpace): string =
  ## A ramp from `a` to `b` across exactly `width` columns.
  ##
  ## This is what the gradient `gauge` does to its filled run, written out here
  ## because the example needs to vary the mix space and `Gradient` has no say in
  ## that — `at` is perceptual by definition. Under half-block the cell's
  ## background is the *next* sample, so `width` cells carry `2 * width` colours.
  if width <= 0: return ""
  let steps = if m.half: width * 2 else: width
  var line: Spans
  for i in 0 ..< width:
    if m.half:
      line.add("▌", Style().fg(lerp(a, b, (2 * i).float / (steps - 1).float, space))
                           .bg(lerp(a, b, (2 * i + 1).float / (steps - 1).float, space)))
    else:
      line.add("█", Style().fg(lerp(a, b, i.float / (steps - 1).float, space)))
  line.render()

proc mixing(m: Model, width, height: int): string =
  ## Every pair drawn both ways, the two rows adjacent so the middle of one can
  ## be compared with the middle of the other.
  let
    t = m.theme
    labelW = 15
    spaceW = 7
    inner = max(width - 2, 1)
    barW = max(inner - labelW - spaceW, 8)
  var rows: seq[string]
  for i, (name, a, b) in Pairs:
    if rows.len + 2 > max(height - 2, 0): break
    if i > 0 and rows.len + 3 <= max(height - 2, 0): rows.add ""
    for space in [msOklab, msSrgb]:
      var line = span(padVisible(if space == msOklab: name else: "", labelW),
                      t.mutedStyle)
      line.add(padVisible(if space == msOklab: "oklab" else: "srgb", spaceW),
               if space == msOklab: t.accentStyle else: t.mutedStyle)
      line.add m.bar(a, b, barW, space)
      rows.add line.render()
  # A title too long for the frame is elided like any other label, and "two way"
  # reads as a bug rather than as a narrow terminal — so it shortens instead.
  renderBox(rows.join("\n"), width, min(height, rows.len + 2),
            title = if inner >= 44: "mixing · the same two colours, two ways"
                    else: "mixing",
            border = SquareBorder, borderStyle = t.borderStyle,
            titleStyle = t.titleStyle)

proc resolution(m: Model, width, height: int): string =
  ## The other axis: the same ramp at several widths, where the number of
  ## colours a row can hold is the whole question.
  let
    t = m.theme
    inner = max(width - 2, 1)
    labelW = 15
  var rows: seq[string]
  for w in [8, 16, 32]:
    # The count on the right is the whole point of the row, so a width that
    # would leave it clipped by the panel is dropped rather than drawn short.
    if labelW + w + len("  64 colours") > inner: continue
    var line = span(padVisible(&"{w} cells", labelW), t.mutedStyle)
    line.add m.bar(hex"#0000ff", hex"#ffff00", w, msOklab)
    line.add span(&"  {(if m.half: w * 2 else: w)} colours", t.mutedStyle)
    rows.add line.render()
  # The widget itself, since that is where anyone will meet this.
  if rows.len > 0: rows.add ""
  let gaugeW = max(inner - labelW - 8, 8)
  var g = span(padVisible("gauge 0.62", labelW), t.mutedStyle)
  g.add(if m.half: gauge(0.62, gaugeW, t.ramp)
        else: gauge(0.62, gaugeW, t.ramp, halfBlock = false))
  rows.add g.render()
  renderBox(rows.join("\n"), width, min(height, rows.len + 2),
            title = if inner >= 40:
                      "resolution · " & (if m.half: "▌, two colours per cell"
                                         else: "█, one colour per cell")
                    else: "resolution",
            border = SquareBorder, borderStyle = t.borderStyle,
            titleStyle = t.titleStyle)

proc borderGallery(m: Model, width, height: int): string =
  ## Every border at the same size, so the choice is a look rather than a name.
  let
    t = m.theme
    perRow = max((width - 2) div (BoxW + 1), 1)
    # Whole rows of boxes or none: a panel sized to `height` would otherwise clip
    # the last row of frames half way down, which reads as a broken border rather
    # than as a short terminal.
    rowsThatFit = max((height - 2) div BoxH, 0)
  if rowsThatFit == 0: return ""
  var
    rows: seq[string]
    row: seq[string]
  for i, (name, b) in Borders:
    if rows.len >= rowsThatFit: break
    # `HiddenBorder` draws nothing, so its body says what it is; the rest are
    # legible from the frame alone.
    row.add renderBox(if name == "hidden": "  blank" else: "",
                      BoxW, BoxH, title = name, border = b,
                      borderStyle = t.borderStyle, titleStyle = t.titleStyle)
    if row.len == perRow or i == Borders.high:
      rows.add joinHorizontal(row, gap = 1)
      row.setLen 0
  var lines: seq[string]
  for r in rows:
    for line in r.split('\n'): lines.add line
  # `lines.len + 2` exactly, never `height`: the count above is already whole
  # box rows, so the panel is sized to them rather than to the space going spare.
  renderBox(lines.join("\n"), width, lines.len + 2,
            title = if width - 2 >= 46:
                      "borders · outer and inner are the half-block pair"
                    else: "borders",
            border = SquareBorder, borderStyle = t.borderStyle,
            titleStyle = t.titleStyle)

proc hintLine(width: int): string =
  ## The longest set that fits, measured rather than guessed at from a width.
  const sets = [
    @[("h", "half-block"), ("t", "theme"), ("q", "quit")],
    @[("h", "half"), ("t", "theme"), ("q", "quit")],
    @[("h", "half"), ("q", "quit")]]
  for s in sets:
    result = hints(s)
    if displayWidth(result) <= width: return

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let
    t = m.theme
    w = m.size.width
  let cells = if m.half: "▌ two colours per cell" else: "█ one colour per cell"
  var lines = @[
    (span(" palette", t.titleStyle) &
     span(&"   {cells} · {ThemeNames[m.themeIndex]}", t.mutedStyle)).render(),
    ""]

  # Sections in priority order, each drawn only if what is left can hold it: the
  # mixing panel is the example, and half a panel says less than none. `left`
  # counts the rows still free below what has been added, the trailing blank and
  # the hints already taken off the top.
  var left = m.size.height - lines.len - 2
  template section(need: int, pane: untyped) =
    if left >= need:
      let drawn = pane
      lines.add drawn
      left -= blockHeight(drawn)
      if left > 1:
        lines.add ""
        dec left

  # Six is one pair and its frame: `mixing` truncates to the height it is given,
  # so a short terminal loses pairs rather than the panel — it is the comparison
  # the example is for, and one pair still makes it.
  section(6, m.mixing(w, left))
  section(6, m.resolution(w, left))
  section(BoxH + 2, m.borderGallery(w, left))

  lines.add hintLine(w)
  lines.join("\n")

when isMainModule:
  discard newProgram(Model(half: true), update, view,
                     options = {poAltScreen, poHideCursor}).run()
