## A named set of colours, and the styles derived from them.
##
## The point is to stop views hardcoding `rgb(120, 220, 200)` in a dozen places.
## A `Theme` is a plain value, so an application holds one in its model, passes
## it to the procs that draw, and can swap the whole palette at runtime:
##
## ```nim
## let t = NeonTheme
## echo renderBox("hello", 20, 5, title = "panel",
##                borderStyle = t.borderStyle, titleStyle = t.titleStyle)
## ```
##
## `derive <#derive,Color>`_ builds a complete theme from a single accent colour
## by rotating hue and adjusting lightness, which is usually enough — picking
## nine colours that agree with each other by hand is the part people get wrong.

import ./[color, style]
export color, style

type
  Theme* = object
    ## Every field is a `Color`; `ckDefault` means "leave it to the terminal",
    ## which is the right value for `bg` in a theme meant to sit on whatever
    ## background the user already has.
    fg*, bg*: Color
    accent*, secondary*: Color
    muted*: Color                      ## de-emphasised text: units, timestamps
    success*, warn*, error*, info*: Color
    border*, borderActive*: Color
    selectionFg*, selectionBg*: Color
    ramp*: Gradient                    ## the theme's gauge/chart gradient

# --- derived styles -----------------------------------------------------------
#
# Procs rather than stored `Style` fields: a Style is three words and building
# one is free, whereas storing them doubles the size of a Theme and makes an
# edit to `accent` silently fail to update `titleStyle`.

proc baseStyle*(t: Theme): Style = Style().fg(t.fg).bg(t.bg)
proc titleStyle*(t: Theme): Style = Style().fg(t.accent).bold()
proc accentStyle*(t: Theme): Style = Style().fg(t.accent)
proc secondaryStyle*(t: Theme): Style = Style().fg(t.secondary)
proc mutedStyle*(t: Theme): Style = Style().fg(t.muted)
proc successStyle*(t: Theme): Style = Style().fg(t.success)
proc warnStyle*(t: Theme): Style = Style().fg(t.warn)
proc errorStyle*(t: Theme): Style = Style().fg(t.error).bold()
proc infoStyle*(t: Theme): Style = Style().fg(t.info)
proc borderStyle*(t: Theme): Style = Style().fg(t.border)
proc activeBorderStyle*(t: Theme): Style = Style().fg(t.borderActive)
proc selectionStyle*(t: Theme): Style = Style().fg(t.selectionFg).bg(t.selectionBg)

proc borderStyleFor*(t: Theme, focused: bool): Style =
  ## The border colour for a pane that may or may not have focus — the check
  ## every multi-pane view writes, in one place.
  if focused: t.activeBorderStyle else: t.borderStyle

# --- deriving -----------------------------------------------------------------

proc derive*(accent: Color, dark = true): Theme =
  ## A complete theme built from one accent colour.
  ##
  ## `secondary` is the accent rotated a third of the way round the wheel, and
  ## the greys are the accent desaturated almost to neutral rather than true
  ## grey — a hint of the accent's hue in the borders is what makes a palette
  ## look chosen instead of assembled. Semantic colours (success, warn, error)
  ## keep their conventional hues, because a red that is not red stops reading
  ## as an error.
  let
    secondary = accent.rotateHue(120)
    muted = accent.desaturate(0.75).darken(if dark: 0.15 else: -0.15)
    border = accent.desaturate(0.6).darken(if dark: 0.3 else: -0.25)
  Theme(
    fg: if dark: hex"#e6edf3" else: hex"#1f2328",
    bg: Color(),                       # the terminal's own background
    accent: accent,
    secondary: secondary,
    muted: muted,
    success: hex"#3fb950",
    warn: hex"#d29922",
    error: hex"#f85149",
    info: hex"#58a6ff",
    border: border,
    borderActive: accent,
    selectionFg: textOn(accent, hex"#0d1117", hex"#ffffff"),
    selectionBg: accent,
    ramp: gradient(accent, secondary))

# --- built-ins ----------------------------------------------------------------

const
  DefaultTheme* = Theme(
    fg: Color(), bg: Color(),
    accent: Color(kind: ckRgb, r: 120, g: 220, b: 200),
    secondary: Color(kind: ckRgb, r: 200, g: 160, b: 255),
    muted: Color(kind: ckRgb, r: 138, g: 148, b: 158),
    success: Color(kind: ckRgb, r: 63, g: 185, b: 80),
    warn: Color(kind: ckRgb, r: 250, g: 200, b: 90),
    error: Color(kind: ckRgb, r: 255, g: 110, b: 110),
    info: Color(kind: ckRgb, r: 88, g: 166, b: 255),
    border: Color(kind: ckRgb, r: 72, g: 84, b: 94),
    borderActive: Color(kind: ckRgb, r: 120, g: 220, b: 200),
    selectionFg: Color(kind: ckRgb, r: 13, g: 17, b: 23),
    selectionBg: Color(kind: ckRgb, r: 120, g: 220, b: 200),
    ramp: CoolGradient)
    ## `fg` and `bg` left to the terminal, so it drops onto any background.

  NeonTheme* = Theme(
    fg: Color(kind: ckRgb, r: 233, g: 236, b: 255),
    bg: Color(),
    accent: Color(kind: ckRgb, r: 0, g: 229, b: 255),
    secondary: Color(kind: ckRgb, r: 197, g: 106, b: 255),
    muted: Color(kind: ckRgb, r: 110, g: 118, b: 160),
    success: Color(kind: ckRgb, r: 57, g: 255, b: 176),
    warn: Color(kind: ckRgb, r: 255, g: 209, b: 102),
    error: Color(kind: ckRgb, r: 255, g: 78, b: 136),
    info: Color(kind: ckRgb, r: 106, g: 176, b: 255),
    border: Color(kind: ckRgb, r: 63, g: 72, b: 122),
    borderActive: Color(kind: ckRgb, r: 0, g: 229, b: 255),
    selectionFg: Color(kind: ckRgb, r: 10, g: 12, b: 24),
    selectionBg: Color(kind: ckRgb, r: 0, g: 229, b: 255),
    ramp: Gradient(stops: @[
      GradientStop(pos: 0.0, color: Color(kind: ckRgb, r: 0, g: 229, b: 255)),
      GradientStop(pos: 1.0, color: Color(kind: ckRgb, r: 255, g: 78, b: 136))]))

  SolarTheme* = Theme(
    fg: Color(kind: ckRgb, r: 253, g: 246, b: 227),
    bg: Color(),
    accent: Color(kind: ckRgb, r: 253, g: 168, b: 44),
    secondary: Color(kind: ckRgb, r: 220, g: 100, b: 60),
    muted: Color(kind: ckRgb, r: 147, g: 134, b: 105),
    success: Color(kind: ckRgb, r: 133, g: 153, b: 0),
    warn: Color(kind: ckRgb, r: 216, g: 152, b: 0),
    error: Color(kind: ckRgb, r: 220, g: 50, b: 47),
    info: Color(kind: ckRgb, r: 38, g: 139, b: 210),
    border: Color(kind: ckRgb, r: 110, g: 96, b: 74),
    borderActive: Color(kind: ckRgb, r: 253, g: 168, b: 44),
    selectionFg: Color(kind: ckRgb, r: 30, g: 24, b: 14),
    selectionBg: Color(kind: ckRgb, r: 253, g: 168, b: 44),
    ramp: SunsetGradient)

  MonoTheme* = Theme(
    fg: Color(), bg: Color(),
    accent: Color(kind: ckRgb, r: 235, g: 235, b: 235),
    secondary: Color(kind: ckRgb, r: 185, g: 185, b: 185),
    muted: Color(kind: ckRgb, r: 125, g: 125, b: 125),
    success: Color(kind: ckRgb, r: 210, g: 210, b: 210),
    warn: Color(kind: ckRgb, r: 175, g: 175, b: 175),
    error: Color(kind: ckRgb, r: 245, g: 245, b: 245),
    info: Color(kind: ckRgb, r: 160, g: 160, b: 160),
    border: Color(kind: ckRgb, r: 90, g: 90, b: 90),
    borderActive: Color(kind: ckRgb, r: 200, g: 200, b: 200),
    selectionFg: Color(kind: ckRgb, r: 20, g: 20, b: 20),
    selectionBg: Color(kind: ckRgb, r: 200, g: 200, b: 200),
    ramp: MonoGradient)
    ## Greyscale throughout, for captures, monochrome terminals, and checking
    ## that a layout still reads when colour carries none of the meaning.

proc grayscale*(t: Theme): Theme =
  ## Every colour desaturated, keeping lightness. Useful for dimming a pane that
  ## does not have focus without writing a second palette.
  result = t
  result.fg = t.fg.grayscale
  result.bg = t.bg.grayscale
  result.accent = t.accent.grayscale
  result.secondary = t.secondary.grayscale
  result.muted = t.muted.grayscale
  result.success = t.success.grayscale
  result.warn = t.warn.grayscale
  result.error = t.error.grayscale
  result.info = t.info.grayscale
  result.border = t.border.grayscale
  result.borderActive = t.borderActive.grayscale
  result.selectionFg = t.selectionFg.grayscale
  result.selectionBg = t.selectionBg.grayscale
  result.ramp.stops = @[]
  for s in t.ramp.stops:
    result.ramp.stops.add GradientStop(pos: s.pos, color: s.color.grayscale)
