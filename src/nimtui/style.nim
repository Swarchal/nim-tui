## Minimal SGR styling.
##
## A `Style` is a value: setters return a copy, so styles compose and can be
## declared as `const`-like module-level constants and reused.
##
## ```nim
## let title = Style().fg(rgb(255, 120, 0)).bold()
## echo title.render("hello")
## ```

import std/[strutils, os]
import ./[ansi, color]
# `Color` and its arithmetic live one layer down, in a module with no
# dependencies at all, so gradients can be computed without dragging in
# escape-sequence assembly. Re-exported for the same reason `ansi` re-exports
# `width`: a caller reaching for `Style` always needs `Color` too.
export color

type
  Attr* = enum
    aBold, aFaint, aItalic, aUnderline, aBlink, aReverse, aStrike

  Style* = object
    fgc*, bgc*: Color
    attrs*: set[Attr]

# --- the colour profile -------------------------------------------------------

var activeProfile = cpTrueColor
  ## Explicitly initialised, twice over. `cpNoColor` is the enum's zero value, so
  ## a bare `var` would silently strip every colour in the library; and detecting
  ## here — either at module load or lazily on the first `sgr` — would make the
  ## bytes this module emits depend on whichever environment happened to import
  ## it. `program.run` resolves it once at startup instead.

proc colorProfile*(): ColorProfile = activeProfile
  ## The profile `sgr <#sgr,Style>`_ and `render <#render,Style,string>`_ use
  ## when not given one.

proc setColorProfile*(p: ColorProfile) =
  ## Set the profile, once, at startup. `program.run` does this for you unless
  ## its `detectColor` is false.
  ##
  ## An accessor rather than a public `var` because a public one is assignable
  ## from inside a `view`, and a profile that changes between frames makes the
  ## renderer's line diff compare bytes that mean different things.
  activeProfile = p

proc profileFor*(noColor, colorterm, term: string): ColorProfile =
  ## The detection rules, with the environment handed in rather than read — so
  ## they can be tested without the suite depending on the terminal it happens to
  ## run under. Same reason `nimtui/query <query.html>`_ takes replies apart
  ## instead of asking a real terminal for one.
  if noColor.len > 0: return cpNoColor
  # `NO_COLOR=` is explicitly *not* a request, which is the common bug: the
  # convention is "set to a non-empty value".
  if term.len == 0 or term == "dumb": return cpNoColor
  # Before `TERM`, not after: `COLORTERM` is the explicit declaration, and under
  # tmux `TERM` is `screen-256color`, which would otherwise silently downgrade a
  # truecolour session to 256.
  if colorterm == "truecolor" or colorterm == "24bit": return cpTrueColor
  if term.contains("truecolor") or term.contains("direct"): return cpTrueColor
  if term.contains("256color"): return cpAnsi256
  if term == "linux" or term.contains("16color"): return cpAnsi16
  # The one guess in this module, kept to a single line so it is easy to change.
  # What reaches here is overwhelmingly an `xterm`/`screen`/`vt100` alias set by
  # an ssh client or a multiplexer in front of an emulator that does support 256,
  # and a terminal that does not understand `38;5;n` is required to ignore the
  # sequence rather than print it. The counter-argument — that guessing high
  # mangles genuinely old terminals — is real but rarer.
  cpAnsi256

proc detectColorProfile*(): ColorProfile =
  ## `profileFor <#profileFor,string,string,string>`_ against the real
  ## environment.
  ##
  ## Deliberately does not ask `isatty`: `program.run` already refuses to start
  ## on something that is not a terminal, and a module of pure string functions
  ## should not be answering questions about `stdout` on the caller's behalf —
  ## the strings it returns may be written anywhere.
  profileFor(getEnv("NO_COLOR"), getEnv("COLORTERM"), getEnv("TERM"))

proc fg*(s: Style, c: Color): Style =
  result = s
  result.fgc = c

proc bg*(s: Style, c: Color): Style =
  result = s
  result.bgc = c

proc with*(s: Style, a: varargs[Attr]): Style =
  result = s
  for x in a: result.attrs.incl x

proc bold*(s: Style): Style = s.with(aBold)
proc faint*(s: Style): Style = s.with(aFaint)
proc italic*(s: Style): Style = s.with(aItalic)
proc underline*(s: Style): Style = s.with(aUnderline)
proc blink*(s: Style): Style = s.with(aBlink)
proc reverse*(s: Style): Style = s.with(aReverse)
proc strike*(s: Style): Style = s.with(aStrike)

proc isEmpty*(s: Style): bool =
  s.attrs.card == 0 and s.fgc.kind == ckDefault and s.bgc.kind == ckDefault

proc merge*(base, over: Style): Style =
  ## `base` with whatever `over` actually specifies laid on top. Attributes
  ## union; a colour in `over` wins, but `ckDefault` means "not specified" and
  ## leaves `base`'s colour alone.
  ##
  ## This is what layering styles needs: a zebra-striped table row supplies a
  ## background and nothing else, and must not wipe out the foreground its
  ## column asked for.
  result = base
  if over.fgc.kind != ckDefault: result.fgc = over.fgc
  if over.bgc.kind != ckDefault: result.bgc = over.bgc
  result.attrs = base.attrs + over.attrs

proc sgr*(s: Style, profile: ColorProfile): string =
  ## The escape sequence that turns `s` on under `profile`, or "" if that leaves
  ## nothing to say.
  ##
  ## Assembled by appending into one buffer rather than joining a `seq[string]`.
  ## A view calls this once per styled line per frame, and the seq plus the
  ## `$`-conversions and concatenations cost a handful of allocations per call —
  ## which measured as the bulk of `render`, and more per frame than the renderer
  ## itself. Keep it allocation-free apart from the result.
  ##
  ## The profile costs one branch per colour, on a path that already switched on
  ## `c.kind`. Note that the truecolour and 256 arms still append the literal
  ## `"38;"` / `"48;"` prefixes rather than computing them: that is deliberate,
  ## and it is what makes those two paths byte-identical to what this emitted
  ## before profiles existed.
  if s.isEmpty: return ""
  result = newStringOfCap(32)
  result.add Csi
  var params = 0
  template param(body: untyped) =
    if params > 0: result.add ';'
    inc params
    body

  # Attributes are emitted under every profile, `cpNoColor` included. `NO_COLOR`
  # is about colour; and this library draws `TextInput`'s cursor with `reverse()`
  # and its placeholder with `faint()`, so a profile that dropped attributes
  # would leave the field with no visible cursor — strictly worse than the colour
  # the user asked to be rid of.
  for a in s.attrs:
    param: result.add(case a
                      of aBold: '1'
                      of aFaint: '2'
                      of aItalic: '3'
                      of aUnderline: '4'
                      of aBlink: '5'
                      of aReverse: '7'
                      of aStrike: '9')

  template colour(c: Color, base: int, ext: string) =
    # `ckDefault` is untouched by every profile: it means "the terminal's own
    # colour", which no profile changes — and under `cpNoColor` every colour
    # effectively becomes one, which is exactly the right semantics.
    if c.kind != ckDefault:
      case profile
      of cpNoColor: discard
      of cpAnsi16:
        # Whole parameters, not `38;5;n`: the sixteen system colours predate the
        # extended form and `ext` has nothing to contribute. 0-7 land at
        # `base + n`, the bright half 8-15 at `base + 52 + n` — 30+52+9 = 91,
        # 40+52+15 = 107. The only path that cannot reuse the prefix.
        let v = c.toAnsi16
        if v.kind == ckAnsi:
          param:
            result.addInt(if v.n < 8: base + v.n else: base + 52 + v.n)
      of cpAnsi256:
        # Only `ckRgb` is converted. A `ckAnsi` already is a palette index, and
        # putting it through `toAnsi256` would resolve it and re-search, landing
        # somewhere else for no reason.
        let v = if c.kind == ckRgb: c.toAnsi256 else: c
        if v.kind == ckAnsi:
          param:
            result.add ext
            result.add "5;"
            result.addInt v.n
      of cpTrueColor:
        case c.kind
        of ckDefault: discard
        of ckAnsi:
          param:
            result.add ext
            result.add "5;"
            result.addInt c.n
        of ckRgb:
          param:
            result.add ext
            result.add "2;"
            result.addInt c.r
            result.add ';'
            result.addInt c.g
            result.add ';'
            result.addInt c.b

  colour(s.fgc, 30, "38;")
  colour(s.bgc, 40, "48;")
  # Required, not cosmetic. A style that is only colours emits no parameters at
  # all under `cpNoColor`, and `"\e[m"` is not nothing — it is a valid SGR
  # meaning reset. `render` below would then wrap text in a reset, and
  # `spans.render`'s `on.len > 0` guards would re-arm it after every embedded
  # one. Unreachable before profiles existed, which is why it was not here.
  if params == 0: return ""
  result.add 'm'

proc sgr*(s: Style): string =
  ## `sgr <#sgr,Style,ColorProfile>`_ under the profile set at startup.
  s.sgr(colorProfile())

proc render*(s: Style, text: string, profile: ColorProfile): string =
  ## Wrap `text` in `s`. Each line is wrapped separately so that the renderer's
  ## per-line erase cannot smear a background colour across the screen.
  let on = s.sgr(profile)
  if on.len == 0: return text
  let firstNl = text.find('\n')
  if firstNl < 0:
    # One line, which is nearly every call: three whole-string appends into one
    # buffer. Splitting into a seq and joining it back, or appending byte by
    # byte, both cost several times as much — and a view does this once per
    # styled line per frame, which adds up to more than the renderer spends.
    result = newStringOfCap(on.len + text.len + Reset.len)
    result.add on
    result.add text
    result.add Reset
  else:
    result = newStringOfCap(text.len + 4 * (on.len + Reset.len))
    var start = 0
    while start <= text.len:
      var stop = text.find('\n', start)
      if stop < 0: stop = text.len
      result.add on
      result.add text[start ..< stop]
      result.add Reset
      if stop == text.len: break
      result.add '\n'
      start = stop + 1

proc render*(s: Style, text: string): string =
  ## `render <#render,Style,string,ColorProfile>`_ under the profile set at
  ## startup.
  s.render(text, colorProfile())
