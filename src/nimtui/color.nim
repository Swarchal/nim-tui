## Colour values and the arithmetic over them: mixing, lightening, contrast,
## and multi-stop gradients.
##
## Nothing here emits an escape sequence — `nimtui/style <style.html>`_ turns a
## `Color` into SGR. This module is pure arithmetic and has no dependencies, so
## it sits at the bottom of the stack next to `nimtui/width <width.html>`_.
##
## ```nim
## let accent = hex"#7b2ff7"
## let dim = accent.darken(0.3)
## let g = gradient(hex"#00d4ff", accent, hex"#ff2e63")
## echo g.at(0.5)          # the colour halfway along
## ```
##
## Mixing is perceptual: `lerp <#lerp,Color,Color,float,MixSpace>`_ and everything
## built on it work in Oklab, so a ramp between two colours passes through the
## colours a person would draw between them rather than through the desaturated
## grey that mixing the bytes gives. `msSrgb` asks for the byte arithmetic where
## a caller needs it — see `MixSpace <#MixSpace>`_.
##
## Every constructor is usable in a `const`, which is the point of keeping the
## parsing free of exceptions on the happy path: `const Accent = hex"#7b2ff7"`
## costs nothing at runtime, and a typo in the literal is a compile error.

import std/math

type
  ColorKind* = enum
    ckDefault,               ## the terminal's own foreground/background
    ckAnsi,                  ## a 256-colour palette index
    ckRgb                    ## 24-bit truecolor

  Color* = object
    ## A colour in one of three representations. `ckDefault` is *unknown*
    ## rather than black: the terminal chooses it, and no arithmetic here can
    ## know what it picked — see `lerp <#lerp,Color,Color,float>`_ for how the
    ## mixing procs handle that.
    kind*: ColorKind
    n*: int                  ## palette index for `ckAnsi` (0..255)
    r*, g*, b*: int          ## components for `ckRgb` (0..255)

  ColorProfile* = enum
    ## How much colour the terminal can be told about. Declared here, beside the
    ## conversions that implement it, rather than in `nimtui/style
    ## <style.html>`_ where it is applied — it describes a representation, and
    ## this module is the one that owns those.
    ##
    ## Ordered by capability, so `<` and `min` read the way they look. The trap
    ## that follows: `cpNoColor` is the zero value, so anything holding one has
    ## to be initialised explicitly or it silently strips every colour.
    cpNoColor,               ## emit no colour at all
    cpAnsi16,                ## the eight basic colours and their bright variants
    cpAnsi256,               ## the xterm 256-colour palette
    cpTrueColor              ## 24-bit

# --- constructors -------------------------------------------------------------

proc ansiColor*(n: int): Color =
  ## 256-colour palette index. 0-7 basic, 8-15 bright, 16-231 cube, 232-255 grey.
  Color(kind: ckAnsi, n: clamp(n, 0, 255))

proc rgb*(r, g, b: int): Color =
  ## 24-bit colour. Terminals without truecolor support will approximate it;
  ## `toAnsi256 <#toAnsi256,Color>`_ does that conversion explicitly.
  ##
  ## Components are clamped, because an out-of-range one would otherwise be
  ## written into the SGR sequence verbatim and produce a malformed escape.
  Color(kind: ckRgb, r: clamp(r, 0, 255), g: clamp(g, 0, 255), b: clamp(b, 0, 255))

proc hexDigit(c: char): int =
  case c
  of '0' .. '9': c.ord - '0'.ord
  of 'a' .. 'f': c.ord - 'a'.ord + 10
  of 'A' .. 'F': c.ord - 'A'.ord + 10
  else: raise newException(ValueError, "not a hex digit: '" & $c & "'")

proc hex*(s: string): Color =
  ## Parse `#rrggbb` or the three-digit shorthand `#rgb`; the `#` is optional.
  ##
  ## Written as a proc taking a string so Nim's generalised raw string literal
  ## applies: `hex"#7b2ff7"` is `hex(r"#7b2ff7")`, which reads like a colour
  ## literal and folds to a constant when used in one.
  let t = if s.len > 0 and s[0] == '#': s[1 .. ^1] else: s
  case t.len
  of 3:
    let (r, g, b) = (hexDigit(t[0]), hexDigit(t[1]), hexDigit(t[2]))
    rgb(r * 17, g * 17, b * 17)          # 0xf -> 0xff, so #abc == #aabbcc
  of 6:
    rgb(hexDigit(t[0]) * 16 + hexDigit(t[1]),
        hexDigit(t[2]) * 16 + hexDigit(t[3]),
        hexDigit(t[4]) * 16 + hexDigit(t[5]))
  else:
    raise newException(ValueError, "expected #rgb or #rrggbb, got: '" & s & "'")

proc gray*(level: float): Color =
  ## A neutral grey, `level` 0 (black) to 1 (white).
  let v = (clamp(level, 0.0, 1.0) * 255.0).round.int
  rgb(v, v, v)

# --- conversions --------------------------------------------------------------

const
  Ansi16: array[16, (int, int, int)] = [
    (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
    (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
    (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    ## xterm's defaults for the sixteen system colours. Only an approximation:
    ## these sixteen are exactly the ones a user's theme is most likely to have
    ## remapped, so a palette index resolved here may not be what is on screen.
  CubeLevels: array[6, int] = [0, 95, 135, 175, 215, 255]

proc toRgb*(c: Color): Color =
  ## Resolve to `ckRgb`. A palette index is looked up in the xterm default
  ## palette; `ckDefault` has no components to resolve and is returned as-is.
  case c.kind
  of ckRgb, ckDefault: c
  of ckAnsi:
    if c.n < 16:
      let (r, g, b) = Ansi16[c.n]
      rgb(r, g, b)
    elif c.n < 232:
      let i = c.n - 16
      rgb(CubeLevels[i div 36], CubeLevels[(i div 6) mod 6], CubeLevels[i mod 6])
    else:
      let v = 8 + (c.n - 232) * 10
      rgb(v, v, v)

proc toAnsi256*(c: Color): Color =
  ## Nearest 256-colour palette entry, for terminals without truecolor.
  ##
  ## Searches the 216-entry cube and the 24-entry grey ramp, but not the first
  ## sixteen — those are the ones a user theme remaps, so matching against their
  ## nominal values would pick a colour that is not the one drawn.
  let v = c.toRgb
  if v.kind != ckRgb: return c

  proc nearestLevel(x: int): int =
    for i in 0 .. 4:
      if x < (CubeLevels[i] + CubeLevels[i + 1]) div 2: return i
    5

  let (ri, gi, bi) = (nearestLevel(v.r), nearestLevel(v.g), nearestLevel(v.b))
  let cube = (CubeLevels[ri], CubeLevels[gi], CubeLevels[bi])
  let greyIdx = clamp((((v.r + v.g + v.b) div 3) - 8 + 5) div 10, 0, 23)
  let greyVal = 8 + greyIdx * 10

  proc dist(a: (int, int, int), r, g, b: int): int =
    let (x, y, z) = a
    (x - r) * (x - r) + (y - g) * (y - g) + (z - b) * (z - b)

  if dist((greyVal, greyVal, greyVal), v.r, v.g, v.b) < dist(cube, v.r, v.g, v.b):
    ansiColor(232 + greyIdx)
  else:
    ansiColor(16 + 36 * ri + 6 * gi + bi)

proc toAnsi16*(c: Color): Color =
  ## Nearest of the sixteen system colours, for a terminal with nothing better.
  ##
  ## Unlike `toAnsi256 <#toAnsi256,Color>`_ this cannot dodge the fact that these
  ## sixteen are the ones a user's theme is most likely to have remapped: with
  ## sixteen slots there is nowhere else to go. That is why it is only reached
  ## when the terminal genuinely has nothing better, and why its tests assert
  ## endpoints and round trips rather than exact values.
  ##
  ## Nearest by squared distance over all sixteen, bright variants included —
  ## the same measure `toAnsi256` uses, and the bright half is where most accent
  ## colours land, so excluding it would make everything muddy. One artefact
  ## worth knowing rather than working around: mid grey lands on index 8, which
  ## many themes draw nearly invisibly on a dark background.
  let v = c.toRgb
  if v.kind != ckRgb: return c
  var best = 0
  var bestD = high(int)
  for i, (r, g, b) in Ansi16:
    let d = (r - v.r) * (r - v.r) + (g - v.g) * (g - v.g) + (b - v.b) * (b - v.b)
    if d < bestD:
      bestD = d
      best = i
  ansiColor(best)

proc toHsl*(c: Color): tuple[h, s, l: float] =
  ## Hue in degrees (0..360), saturation and lightness in 0..1.
  let v = c.toRgb
  if v.kind != ckRgb: return (0.0, 0.0, 0.0)
  let
    r = v.r.float / 255.0
    g = v.g.float / 255.0
    b = v.b.float / 255.0
    hi = max(max(r, g), b)
    lo = min(min(r, g), b)
    l = (hi + lo) / 2.0
    d = hi - lo
  if d < 1e-9: return (0.0, 0.0, l)
  let s = d / (1.0 - abs(2.0 * l - 1.0))
  var h =
    if hi == r: 60.0 * floorMod((g - b) / d, 6.0)
    elif hi == g: 60.0 * ((b - r) / d + 2.0)
    else: 60.0 * ((r - g) / d + 4.0)
  (h, clamp(s, 0.0, 1.0), l)

proc hsl*(h, s, l: float): Color =
  ## Build a colour from hue (degrees), saturation and lightness (0..1).
  ## Hue wraps, so `hsl(390, ...)` is `hsl(30, ...)` and stepping the hue to
  ## generate a palette needs no modulo at the call site.
  let
    hh = floorMod(h, 360.0)
    ss = clamp(s, 0.0, 1.0)
    ll = clamp(l, 0.0, 1.0)
    c = (1.0 - abs(2.0 * ll - 1.0)) * ss
    x = c * (1.0 - abs(floorMod(hh / 60.0, 2.0) - 1.0))
    m = ll - c / 2.0
  var (r, g, b) = (0.0, 0.0, 0.0)
  if hh < 60: (r, g, b) = (c, x, 0.0)
  elif hh < 120: (r, g, b) = (x, c, 0.0)
  elif hh < 180: (r, g, b) = (0.0, c, x)
  elif hh < 240: (r, g, b) = (0.0, x, c)
  elif hh < 300: (r, g, b) = (x, 0.0, c)
  else: (r, g, b) = (c, 0.0, x)
  rgb(((r + m) * 255.0).round.int, ((g + m) * 255.0).round.int,
      ((b + m) * 255.0).round.int)

# --- arithmetic ---------------------------------------------------------------

type
  MixSpace* = enum
    ## Which space `lerp <#lerp,Color,Color,float,MixSpace>`_ mixes in.
    ##
    ## `msOklab` is perceptual and is the default: a ramp between two colours
    ## that are not near-neighbours in hue passes through the colours a person
    ## would draw between them. `msSrgb` mixes the bytes, which is what every
    ## naive implementation does and what this one did — blue to yellow sags
    ## through a desaturated grey at the midpoint, because sRGB's axes are not
    ## perceptual and the shortest line between two of its corners leaves the
    ## saturated part of the space.
    ##
    ## It stays reachable because it is exact and cheap, and because a caller
    ## reproducing a palette from somewhere else wants the arithmetic that
    ## palette was built with.
    msOklab,
    msSrgb

const SrgbToLinear = block:
  ## sRGB byte to linear light. A table because the forward direction only ever
  ## sees an integer channel, so all 256 answers are known at compile time —
  ## which removes three `pow`s per conversion and makes the table exact rather
  ## than an approximation of one.
  var t: array[256, float]
  for i in 0 .. 255:
    let c = i.float / 255.0
    t[i] = if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)
  t

proc linearToSrgb(x: float): int =
  ## The way back, which does need a `pow` — the input is an arbitrary float.
  let c = clamp(x, 0.0, 1.0)
  let s = if c <= 0.0031308: c * 12.92 else: 1.055 * pow(c, 1.0 / 2.4) - 0.055
  (s * 255.0).round.int

proc toOklab(c: Color): tuple[l, a, b: float] =
  ## Björn Ottosson's Oklab: linear sRGB through the LMS cone responses, cube
  ## rooted, then rotated into a lightness and two opponent axes.
  let
    p = c.toRgb
    r = SrgbToLinear[p.r]
    g = SrgbToLinear[p.g]
    b = SrgbToLinear[p.b]
    l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
   1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
   0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)

proc fromOklab(lab: tuple[l, a, b: float]): Color =
  ## The inverse. The cubes are the cheap direction; only the sRGB transfer
  ## function at the end costs anything.
  let
    l = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
    m = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
    s = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
    l3 = l * l * l
    m3 = m * m * m
    s3 = s * s * s
  rgb(linearToSrgb(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
      linearToSrgb(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
      linearToSrgb(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))

proc lerp*(a, b: Color, t: float, space = msOklab): Color =
  ## Mix `a` into `b`, `t` from 0 to 1, perceptually unless told otherwise.
  ##
  ## An unknown (`ckDefault`) endpoint has no components to mix, so the *other*
  ## endpoint is returned rather than the black it is not: treating the
  ## terminal's own colour as `#000000` silently produces a ramp that is wrong
  ## on every light background.
  ##
  ## Both endpoints come back exactly, by returning them rather than by mixing
  ## them: a round trip through Oklab is a float conversion in each direction and
  ## can land a component one off, and a gradient whose first colour is not quite
  ## the colour it was given is the kind of wrong that is never noticed and never
  ## forgiven. `Gradient.at <#at,Gradient,float>`_ clamps into this.
  if a.kind == ckDefault: return b
  if b.kind == ckDefault: return a
  let x = clamp(t, 0.0, 1.0)
  # `a` and `b`, not `a.toRgb` and `b.toRgb`: exactly is exactly, and `toRgb`
  # resolves a palette index into the xterm default for it. That is a no-op for
  # a `ckRgb` stop, which is why it looked harmless, but it turns an endpoint the
  # caller wrote as `ansiColor(2)` into `rgb(0, 128, 0)` — and `sgr` treats the
  # two differently on purpose, so under `cpAnsi256` the stop comes out as cube
  # index 28 rather than as index 2. The first sixteen are precisely the entries
  # a user's theme remaps, so that is the caller's green replaced by xterm's.
  if x <= 0.0: return a
  if x >= 1.0: return b
  case space
  of msSrgb:
    let
      p = a.toRgb
      q = b.toRgb
    rgb((p.r.float + (q.r - p.r).float * x).round.int,
        (p.g.float + (q.g - p.g).float * x).round.int,
        (p.b.float + (q.b - p.b).float * x).round.int)
  of msOklab:
    let
      p = a.toOklab
      q = b.toOklab
    fromOklab((p.l + (q.l - p.l) * x,
               p.a + (q.a - p.a) * x,
               p.b + (q.b - p.b) * x))

proc lighten*(c: Color, amount: float): Color =
  ## Raise lightness by `amount` (0..1) in HSL, keeping hue and saturation.
  if c.kind == ckDefault: return c
  let (h, s, l) = c.toHsl
  hsl(h, s, l + amount)

proc darken*(c: Color, amount: float): Color =
  ## Lower lightness by `amount` (0..1) in HSL, keeping hue and saturation.
  if c.kind == ckDefault: return c
  let (h, s, l) = c.toHsl
  hsl(h, s, l - amount)

proc saturate*(c: Color, amount: float): Color =
  if c.kind == ckDefault: return c
  let (h, s, l) = c.toHsl
  hsl(h, s + amount, l)

proc desaturate*(c: Color, amount: float): Color =
  c.saturate(-amount)

proc rotateHue*(c: Color, degrees: float): Color =
  ## Shift the hue. Useful for deriving a palette from one accent colour:
  ## `accent.rotateHue(120)` and `accent.rotateHue(240)` give a triad.
  if c.kind == ckDefault: return c
  let (h, s, l) = c.toHsl
  hsl(h + degrees, s, l)

proc grayscale*(c: Color): Color =
  ## Drop saturation entirely, preserving perceived lightness.
  if c.kind == ckDefault: return c
  let v = c.toRgb
  # Rec. 601 luma, not a flat mean: a flat mean turns saturated blue and
  # saturated yellow into the same grey, which is not how they look.
  let y = (0.299 * v.r.float + 0.587 * v.g.float + 0.114 * v.b.float).round.int
  rgb(y, y, y)

proc luminance*(c: Color): float =
  ## WCAG relative luminance, 0 (black) to 1 (white). `ckDefault` is unknown and
  ## reported as mid-grey, which biases nothing in either direction.
  if c.kind == ckDefault: return 0.5
  let v = c.toRgb
  proc channel(x: int): float =
    let f = x.float / 255.0
    if f <= 0.03928: f / 12.92 else: pow((f + 0.055) / 1.055, 2.4)
  0.2126 * channel(v.r) + 0.7152 * channel(v.g) + 0.0722 * channel(v.b)

proc contrastRatio*(a, b: Color): float =
  ## WCAG contrast ratio, 1 (identical) to 21 (black on white). WCAG AA wants
  ## 4.5 for body text; terminal UIs usually aim lower, but under 2 is unreadable.
  let
    x = a.luminance
    y = b.luminance
  if x > y: (x + 0.05) / (y + 0.05) else: (y + 0.05) / (x + 0.05)

proc textOn*(bg: Color, dark = rgb(0, 0, 0), light = rgb(255, 255, 255)): Color =
  ## Whichever of `dark`/`light` contrasts better against `bg` — for text drawn
  ## on a generated background, where the caller cannot know in advance whether
  ## the fill came out pale or deep.
  if contrastRatio(bg, dark) >= contrastRatio(bg, light): dark else: light

# --- gradients ----------------------------------------------------------------

type
  GradientStop* = object
    pos*: float              ## 0..1 along the gradient
    color*: Color

  Gradient* = object
    ## A colour ramp defined by stops. Sample it with `at <#at,Gradient,float>`_.
    ## An empty gradient samples to `ckDefault`, so a zero-valued `Gradient`
    ## field means "no colour" rather than being a trap.
    stops*: seq[GradientStop]

proc gradient*(colors: varargs[Color]): Gradient =
  ## A gradient through `colors`, evenly spaced.
  if colors.len == 0: return Gradient()
  if colors.len == 1:
    return Gradient(stops: @[GradientStop(pos: 0.0, color: colors[0])])
  result.stops = newSeqOfCap[GradientStop](colors.len)
  for i, c in colors:
    result.stops.add GradientStop(pos: i.float / (colors.len - 1).float, color: c)

proc gradient*(stops: openArray[(float, Color)]): Gradient =
  ## A gradient with explicitly positioned stops, for a ramp that should not be
  ## even — a gauge that stays green until 70% and then reddens quickly, say.
  ## Stops are expected in ascending order of position.
  result.stops = newSeqOfCap[GradientStop](stops.len)
  for (p, c) in stops:
    result.stops.add GradientStop(pos: clamp(p, 0.0, 1.0), color: c)

proc at*(g: Gradient, t: float): Color =
  ## The colour at `t` (0..1), interpolated between the surrounding stops.
  ## `t` is clamped, so a caller need not bound a ratio it computed.
  if g.stops.len == 0: return Color()
  let x = clamp(t, 0.0, 1.0)
  if g.stops.len == 1 or x <= g.stops[0].pos: return g.stops[0].color
  if x >= g.stops[^1].pos: return g.stops[^1].color
  for i in 1 .. g.stops.high:
    if x <= g.stops[i].pos:
      let
        a = g.stops[i - 1]
        b = g.stops[i]
        span = b.pos - a.pos
      # Two stops at the same position are a hard edge, not a division by zero.
      return if span <= 0.0: b.color else: lerp(a.color, b.color, (x - a.pos) / span)
  g.stops[^1].color

proc ramp*(g: Gradient, n: int): seq[Color] =
  ## `n` colours evenly sampled along `g`, endpoints included.
  ##
  ## Sampling once into a seq is the right shape for colouring a row of cells:
  ## the alternative, calling `at` per cell, redoes the stop search every time.
  ##
  ## It also converts each stop into Oklab once and reuses it across every sample
  ## that falls in the same segment, where `at` has to convert both ends on every
  ## call — two thirds of the work of a perceptual mix is in that direction, and
  ## a ramp is where the samples come in bulk. Every colour it returns is exactly
  ## `at(i / (n - 1))`, which `tcolor.nim` pins: this is the same arithmetic with
  ## the repeated part hoisted, not a second implementation of it.
  if n <= 0: return @[]
  if n == 1: return @[g.at(0.5)]
  result = newSeqOfCap[Color](n)
  var
    seg = -1                     ## which segment `lo`/`hi` were converted from
    lo, hi: tuple[l, a, b: float]
  for i in 0 ..< n:
    let x = i.float / (n - 1).float
    # The three cases `at` answers without mixing at all, in its order.
    if g.stops.len == 1 or x <= g.stops[0].pos:
      result.add g.stops[0].color
      continue
    if x >= g.stops[^1].pos:
      result.add g.stops[^1].color
      continue
    var j = 1
    while j < g.stops.high and x > g.stops[j].pos: inc j
    let
      a = g.stops[j - 1]
      b = g.stops[j]
      span = b.pos - a.pos
    if span <= 0.0:                                   # a hard edge
      result.add b.color
      continue
    let t = (x - a.pos) / span
    # An unknown endpoint has nothing to convert, and the endpoints themselves
    # must come back exactly — both are `lerp`'s rules, and deferring to it is
    # what keeps them in one place rather than restated here.
    if a.color.kind == ckDefault or b.color.kind == ckDefault or
       t <= 0.0 or t >= 1.0:
      result.add lerp(a.color, b.color, t)
      continue
    if j != seg:
      seg = j
      lo = a.color.toOklab
      hi = b.color.toOklab
    result.add fromOklab((lo.l + (hi.l - lo.l) * t,
                          lo.a + (hi.a - lo.a) * t,
                          lo.b + (hi.b - lo.b) * t))

proc reversed*(g: Gradient): Gradient =
  ## The same ramp read right to left.
  result.stops = newSeqOfCap[GradientStop](g.stops.len)
  for i in countdown(g.stops.high, 0):
    result.stops.add GradientStop(pos: 1.0 - g.stops[i].pos, color: g.stops[i].color)

proc isEmpty*(g: Gradient): bool =
  g.stops.len == 0

const
  HeatGradient* = Gradient(stops: @[
    GradientStop(pos: 0.0, color: Color(kind: ckRgb, r: 74, g: 222, b: 128)),
    GradientStop(pos: 0.5, color: Color(kind: ckRgb, r: 250, g: 204, b: 21)),
    GradientStop(pos: 1.0, color: Color(kind: ckRgb, r: 248, g: 81, b: 73))])
    ## Green to amber to red — load, utilisation, anything where high is bad.

  CoolGradient* = Gradient(stops: @[
    GradientStop(pos: 0.0, color: Color(kind: ckRgb, r: 34, g: 211, b: 238)),
    GradientStop(pos: 1.0, color: Color(kind: ckRgb, r: 129, g: 79, b: 247))])
    ## Cyan to violet — the default accent ramp, neutral about magnitude.

  SunsetGradient* = Gradient(stops: @[
    GradientStop(pos: 0.0, color: Color(kind: ckRgb, r: 255, g: 202, b: 122)),
    GradientStop(pos: 0.5, color: Color(kind: ckRgb, r: 249, g: 115, b: 156)),
    GradientStop(pos: 1.0, color: Color(kind: ckRgb, r: 118, g: 74, b: 188))])

  RainbowGradient* = Gradient(stops: @[
    GradientStop(pos: 0.00, color: Color(kind: ckRgb, r: 255, g: 94, b: 94)),
    GradientStop(pos: 0.20, color: Color(kind: ckRgb, r: 255, g: 183, b: 77)),
    GradientStop(pos: 0.40, color: Color(kind: ckRgb, r: 255, g: 241, b: 118)),
    GradientStop(pos: 0.60, color: Color(kind: ckRgb, r: 129, g: 220, b: 143)),
    GradientStop(pos: 0.80, color: Color(kind: ckRgb, r: 100, g: 181, b: 246)),
    GradientStop(pos: 1.00, color: Color(kind: ckRgb, r: 186, g: 134, b: 252))])

  MonoGradient* = Gradient(stops: @[
    GradientStop(pos: 0.0, color: Color(kind: ckRgb, r: 60, g: 60, b: 60)),
    GradientStop(pos: 1.0, color: Color(kind: ckRgb, r: 230, g: 230, b: 230))])
    ## For terminals or captures where colour is unavailable or unwanted.
