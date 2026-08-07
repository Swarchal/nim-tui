import std/[unittest, math]
import nimtui/[color, theme]

## Colour arithmetic is easy to write and hard to eyeball, so the checks here are
## the ones a wrong formula fails: round trips, endpoints, and the treatment of
## `ckDefault`, which is *unknown* rather than black and is where a naive
## implementation quietly turns every ramp wrong on a light terminal.

const Accent = hex"#7b2ff7"
const Ramp = gradient(hex"#00d4ff", Accent, hex"#ff2e63")

suite "colour constructors":
  test "hex parses both lengths, and folds at compile time":
    check hex"#ff7043" == rgb(255, 112, 67)
    check hex"ff7043" == rgb(255, 112, 67)
    # A `const` proves the parse runs in the VM: a runtime-only proc would not
    # compile here at all.
    check Accent == rgb(123, 47, 247)

  test "the three-digit form doubles each digit":
    check hex"#abc" == hex"#aabbcc"
    check hex"#fff" == rgb(255, 255, 255)

  test "a bad literal is rejected":
    expect ValueError: discard hex"#12345"
    expect ValueError: discard hex"#gggggg"

  test "components are clamped rather than emitted out of range":
    check rgb(300, -20, 40) == rgb(255, 0, 40)
    check ansiColor(999).n == 255

suite "colour conversion":
  test "the palette cube resolves to its documented levels":
    check ansiColor(16).toRgb == rgb(0, 0, 0)
    check ansiColor(231).toRgb == rgb(255, 255, 255)
    check ansiColor(196).toRgb == rgb(255, 0, 0)

  test "the grey ramp resolves":
    check ansiColor(232).toRgb == rgb(8, 8, 8)
    check ansiColor(255).toRgb == rgb(238, 238, 238)

  test "toAnsi256 picks a near neighbour":
    check hex"#ff0000".toAnsi256 == ansiColor(196)
    check hex"#000000".toAnsi256 == ansiColor(16)
    # Round trip: the nearest entry, resolved back, is close to where it started.
    #
    # 48 rather than something tighter because that is the palette's own
    # coarseness, not slack in the search: the cube's levels are
    # [0, 95, 135, 175, 215, 255], so the 0..95 step is 95 wide and a component
    # landing in the middle of it — #7b2ff7's green of 47 — is 48 from either
    # end whatever the algorithm does.
    for c in [hex"#7b2ff7", hex"#22d3ee", hex"#4ade80", gray(0.5)]:
      let back = c.toAnsi256.toRgb
      check abs(back.r - c.r) <= 48
      check abs(back.g - c.g) <= 48
      check abs(back.b - c.b) <= 48

  test "toAnsi16 round-trips the sixteen it can represent":
    for n in 0 .. 15:
      check ansiColor(n).toAnsi16 == ansiColor(n)

  test "toAnsi16 gets the endpoints exact":
    check hex"#000000".toAnsi16 == ansiColor(0)
    check hex"#ffffff".toAnsi16 == ansiColor(15)
    check hex"#ff0000".toAnsi16 == ansiColor(9)     # bright red, not the dim 1
    check hex"#000080".toAnsi16 == ansiColor(4)

  test "toAnsi16 leaves an unknown colour unknown":
    check Color().toAnsi16.kind == ckDefault

  test "every colour lands inside the sixteen":
    # No round-trip bound here: with sixteen slots the nearest entry can be a
    # long way off, and asserting a distance would only be asserting the
    # palette's coarseness. That it always lands *somewhere* valid is the part
    # that matters — an out-of-range index becomes a malformed escape.
    for c in [hex"#7b2ff7", hex"#22d3ee", hex"#4ade80", gray(0.5), gray(0.0),
              ansiColor(196), ansiColor(240)]:
      let v = c.toAnsi16
      check v.kind == ckAnsi
      check v.n in 0 .. 15

  test "toAnsi256 prefers the grey ramp when it is the closer match":
    # The grey ramp is finer than the cube's diagonal, so a neutral colour must
    # come back exact rather than snapping to the nearest cube corner.
    check gray(0.5).toAnsi256.toRgb == rgb(128, 128, 128)
    check hex"#121212".toAnsi256.toRgb == rgb(18, 18, 18)

  test "hsl round-trips through toHsl":
    for c in [hex"#7b2ff7", hex"#22d3ee", hex"#4ade80", hex"#808080"]:
      let (h, s, l) = c.toHsl
      let back = hsl(h, s, l)
      check abs(back.r - c.r) <= 1
      check abs(back.g - c.g) <= 1
      check abs(back.b - c.b) <= 1

  test "hue wraps, so stepping a palette needs no modulo":
    check hsl(390, 0.5, 0.5) == hsl(30, 0.5, 0.5)
    check hsl(-30, 0.5, 0.5) == hsl(330, 0.5, 0.5)

suite "colour arithmetic":
  test "lerp hits both endpoints exactly, in either space":
    # Exactly, and by returning the endpoint rather than mixing it: a round trip
    # through Oklab converts in both directions and can land a component one off,
    # which makes a gradient's first colour not quite the colour it was given.
    for space in [msOklab, msSrgb]:
      check lerp(hex"#000000", hex"#ffffff", 0.0, space) == hex"#000000"
      check lerp(hex"#000000", hex"#ffffff", 1.0, space) == hex"#ffffff"
      check lerp(hex"#123456", hex"#abcdef", 0.0, space) == hex"#123456"
      check lerp(hex"#123456", hex"#abcdef", 1.0, space) == hex"#abcdef"

  test "msSrgb still mixes the bytes":
    # The pin on the old behaviour: this is what every naive implementation
    # does, it is what this one did before Oklab, and a caller reproducing a
    # palette built that way needs it to stay exact.
    check lerp(hex"#000000", hex"#ffffff", 0.5, msSrgb) == rgb(128, 128, 128)
    check lerp(hex"#0000ff", hex"#ffff00", 0.5, msSrgb) == rgb(128, 128, 128)

  test "the default mix keeps saturation across the middle":
    # The reason for Oklab. Blue to yellow is the worst case: in sRGB the
    # shortest line between those corners leaves the saturated part of the space
    # and the midpoint is a dead grey, which is not a colour anyone would pick
    # halfway between them.
    let
      mid = lerp(hex"#0000ff", hex"#ffff00", 0.5)
      (_, sat, _) = mid.toHsl
      (_, flatSat, _) = lerp(hex"#0000ff", hex"#ffff00", 0.5, msSrgb).toHsl
    check sat > flatSat
    check flatSat < 0.01                # grey, as the sRGB pin above spells out
    check sat > 0.2

  test "lightness rises monotonically along a ramp":
    # True in both spaces, and the cheapest guard against a transposed matrix
    # coefficient: a wrong one still returns plausible colours, but the ramp
    # stops being ordered.
    for space in [msOklab, msSrgb]:
      var last = -1.0
      for i in 0 .. 16:
        let (_, _, l) = lerp(hex"#000000", hex"#ffffff", i.float / 16.0, space).toHsl
        check l >= last
        last = l

  test "a lerp is usable in a const":
    # `color` has no dependencies and emits no escapes so that a palette can be
    # computed at compile time; Oklab's `pow` and `cbrt` both evaluate in the VM,
    # and this fails to compile rather than fails a check if that stops holding.
    const Mid = lerp(hex"#0000ff", hex"#ffff00", 0.5)
    check Mid.kind == ckRgb

  test "ramp is exactly at, sample for sample":
    # `ramp` hoists the Oklab conversion of each stop out of the loop, which is
    # the same arithmetic with the repeated part moved — not a second
    # implementation. This is what says so, over uneven stops, hard edges, an
    # unknown endpoint and a single-stop gradient.
    let cases = [gradient(hex"#0000ff", hex"#ffff00"),
                 gradient(hex"#00d4ff", hex"#7b2ff7", hex"#ff2e63"),
                 gradient({0.0: hex"#000000", 0.2: hex"#ff0000",
                           0.2: hex"#00ff00", 1.0: hex"#ffffff"}),
                 gradient(Color(), hex"#ff0000"),
                 gradient(hex"#123456"),
                 HeatGradient, RainbowGradient]
    for g in cases:
      for n in [2, 3, 5, 8, 16, 40, 97]:
        let r = g.ramp(n)
        check r.len == n
        for i in 0 ..< n:
          checkpoint "n=" & $n & " i=" & $i
          check r[i] == g.at(i.float / (n - 1).float)

  test "lerp clamps t rather than extrapolating":
    check lerp(hex"#000000", hex"#ffffff", -5.0) == hex"#000000"
    check lerp(hex"#000000", hex"#ffffff", 5.0) == hex"#ffffff"

  test "an unknown endpoint yields the other, not black":
    # The bug this guards: treating the terminal's own colour as #000000 makes
    # every gradient against it wrong, and wrong in a way only visible on a
    # light background.
    check lerp(Color(), Accent, 0.5) == Accent
    check lerp(Accent, Color(), 0.5) == Accent
    check Color().lighten(0.5).kind == ckDefault
    check Color().rotateHue(90).kind == ckDefault

  test "lighten and darken move lightness and keep hue":
    let (h0, _, l0) = Accent.toHsl
    let (h1, _, l1) = Accent.lighten(0.2).toHsl
    let (h2, _, l2) = Accent.darken(0.2).toHsl
    check l1 > l0
    check l2 < l0
    check abs(h1 - h0) < 1.0
    check abs(h2 - h0) < 1.0

  test "lightness saturates instead of wrapping":
    check hex"#ffffff".lighten(0.5) == hex"#ffffff"
    check hex"#000000".darken(0.5) == hex"#000000"

  test "grayscale is luma-weighted, not a flat mean":
    # A flat mean would collapse saturated blue and saturated yellow onto the
    # same grey, which is not how they look.
    check hex"#0000ff".grayscale != hex"#ffff00".grayscale
    check hex"#0000ff".grayscale.r < hex"#ffff00".grayscale.r

  test "contrast runs from 1 to 21":
    check abs(contrastRatio(hex"#000000", hex"#ffffff") - 21.0) < 0.01
    check abs(contrastRatio(Accent, Accent) - 1.0) < 0.01

  test "textOn picks the readable side":
    check textOn(hex"#ffffff") == rgb(0, 0, 0)
    check textOn(hex"#101010") == rgb(255, 255, 255)

suite "gradients":
  test "at hits the stops and clamps outside them":
    check Ramp.at(0.0) == hex"#00d4ff"
    check Ramp.at(0.5) == Accent
    check Ramp.at(1.0) == hex"#ff2e63"
    check Ramp.at(-1.0) == Ramp.at(0.0)
    check Ramp.at(2.0) == Ramp.at(1.0)

  test "evenly spaced stops land where they say":
    let g = gradient(hex"#000000", hex"#888888", hex"#ffffff")
    check g.stops.len == 3
    check g.stops[1].pos == 0.5

  test "explicit stops allow an uneven ramp":
    let g = gradient({0.0: hex"#4ade80", 0.7: hex"#4ade80",
                      1.0: hex"#f85149"})
    check g.at(0.35) == hex"#4ade80"        # flat until the knee
    check g.at(1.0) == hex"#f85149"

  test "two stops at one position are a hard edge, not a divide by zero":
    let g = gradient({0.0: hex"#000000", 0.5: hex"#000000",
                      0.5: hex"#ffffff", 1.0: hex"#ffffff"})
    check g.at(0.25) == hex"#000000"
    check g.at(0.75) == hex"#ffffff"

  test "ramp includes both endpoints":
    let r = Ramp.ramp(5)
    check r.len == 5
    check r[0] == Ramp.at(0.0)
    check r[^1] == Ramp.at(1.0)

  test "degenerate gradients do not crash":
    check Gradient().isEmpty
    check Gradient().at(0.5).kind == ckDefault
    check gradient(Accent).at(0.9) == Accent
    check Ramp.ramp(0).len == 0
    check Ramp.ramp(1).len == 1

  test "reversed mirrors the ramp":
    check Ramp.reversed.at(0.0) == Ramp.at(1.0)
    check Ramp.reversed.at(1.0) == Ramp.at(0.0)

  test "the built-in ramps are ordered and non-empty":
    for g in [HeatGradient, CoolGradient, SunsetGradient, RainbowGradient,
              MonoGradient]:
      check not g.isEmpty
      check g.stops[0].pos == 0.0
      check g.stops[^1].pos == 1.0
      for i in 1 .. g.stops.high:
        check g.stops[i].pos >= g.stops[i - 1].pos

suite "theme":
  test "the built-ins define every semantic colour":
    for t in [DefaultTheme, NeonTheme, SolarTheme, MonoTheme]:
      for c in [t.accent, t.secondary, t.muted, t.success, t.warn, t.error,
                t.info, t.border, t.borderActive]:
        check c.kind != ckDefault
      check not t.ramp.isEmpty

  test "derive builds a usable palette from one colour":
    let t = derive(Accent)
    check t.accent == Accent
    check t.borderActive == Accent
    check t.secondary != Accent
    check not t.ramp.isEmpty
    # The selection foreground has to be legible on the selection background,
    # which is the accent — that is the whole point of choosing it with `textOn`.
    check contrastRatio(t.selectionFg, t.selectionBg) > 3.0

  test "derived styles follow the fields":
    let t = derive(hex"#22d3ee")
    check t.titleStyle.fgc == t.accent
    check t.errorStyle.fgc == t.error
    check t.borderStyleFor(true).fgc == t.borderActive
    check t.borderStyleFor(false).fgc == t.border

  test "grayscale desaturates the whole theme":
    let g = NeonTheme.grayscale
    check g.accent.r == g.accent.g
    check g.accent.g == g.accent.b
    check g.ramp.stops.len == NeonTheme.ramp.stops.len
    for s in g.ramp.stops:
      check s.color.r == s.color.b
