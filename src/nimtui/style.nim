## Minimal SGR styling.
##
## A `Style` is a value: setters return a copy, so styles compose and can be
## declared as `const`-like module-level constants and reused.
##
## ```nim
## let title = Style().fg(rgb(255, 120, 0)).bold()
## echo title.render("hello")
## ```

import std/strutils
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

proc sgr*(s: Style): string =
  ## The escape sequence that turns `s` on, or "" for an empty style.
  ##
  ## Assembled by appending into one buffer rather than joining a `seq[string]`.
  ## A view calls this once per styled line per frame, and the seq plus the
  ## `$`-conversions and concatenations cost a handful of allocations per call —
  ## which measured as the bulk of `render`, and more per frame than the renderer
  ## itself. Keep it allocation-free apart from the result.
  if s.isEmpty: return ""
  result = newStringOfCap(32)
  result.add Csi
  var params = 0
  template param(body: untyped) =
    if params > 0: result.add ';'
    inc params
    body

  for a in s.attrs:
    param: result.add(case a
                      of aBold: '1'
                      of aFaint: '2'
                      of aItalic: '3'
                      of aUnderline: '4'
                      of aBlink: '5'
                      of aReverse: '7'
                      of aStrike: '9')

  template colour(c: Color, base: string) =
    case c.kind
    of ckDefault: discard
    of ckAnsi:
      param:
        result.add base
        result.add "5;"
        result.addInt c.n
    of ckRgb:
      param:
        result.add base
        result.add "2;"
        result.addInt c.r
        result.add ';'
        result.addInt c.g
        result.add ';'
        result.addInt c.b

  colour(s.fgc, "38;")
  colour(s.bgc, "48;")
  result.add 'm'

proc render*(s: Style, text: string): string =
  ## Wrap `text` in `s`. Each line is wrapped separately so that the renderer's
  ## per-line erase cannot smear a background colour across the screen.
  let on = s.sgr()
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
