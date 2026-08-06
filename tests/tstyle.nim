import std/[unittest, strutils]
import nimtui/[ansi, style]

suite "sgr":
  test "an empty style produces no escape":
    check Style().sgr() == ""
    check Style().isEmpty
    check Style().render("plain") == "plain"

  test "attributes":
    check Style().bold().sgr() == "\e[1m"
    check Style().underline().sgr() == "\e[4m"

  test "attributes are emitted in a stable order":
    check Style().bold().italic().sgr() == Style().italic().bold().sgr()

  test "256-colour palette":
    check Style().fg(ansiColor(196)).sgr() == "\e[38;5;196m"
    check Style().bg(ansiColor(17)).sgr() == "\e[48;5;17m"

  test "truecolor":
    check Style().fg(rgb(255, 128, 0)).sgr() == "\e[38;2;255;128;0m"

  test "combined":
    check Style().bold().fg(ansiColor(1)).bg(ansiColor(2)).sgr() ==
      "\e[1;38;5;1;48;5;2m"

suite "composition":
  test "styles are values, so setters do not mutate the original":
    let base = Style().fg(ansiColor(1))
    let derived = base.bold()
    check base.attrs == {}
    check derived.attrs == {aBold}
    check derived.fgc.n == 1

suite "render":
  test "wraps text and resets":
    let s = Style().bold()
    check s.render("hi") == "\e[1mhi" & Reset

  test "each line is wrapped separately so backgrounds cannot smear":
    let s = Style().bg(ansiColor(4))
    let rendered = s.render("a\nb")
    check rendered.count(Reset) == 2
    check rendered.splitLines.len == 2

  test "styled text keeps its visible width":
    check displayWidth(Style().bold().fg(rgb(1, 2, 3)).render("hello")) == 5

suite "renderOver":
  ## A container's style has to survive a reset in the content it contains. The
  ## failure this pins is invisible to a dimensional assertion — the right number
  ## of columns in the wrong colour — so these check the bytes.
  const
    fill = Style().bg(ansiColor(4))
    inner = Style().fg(ansiColor(7))

  test "the container is re-armed after a reset in the content":
    # `"hi"` styled by the caller, then padded: exactly what a panel fill is
    # handed. Under `render` the eight pad columns come out bare.
    let content = inner.render("hi", cpAnsi256) & "        "
    let over = fill.renderOver(content, cpAnsi256)
    check (Reset & fill.sgr(cpAnsi256)) in over
    check over.count(fill.sgr(cpAnsi256)) == 2   # opened once, re-armed once
    check over.endsWith(Reset)

  test "every reset is re-armed, not only the first":
    let content = inner.render("a", cpAnsi256) & inner.render("b", cpAnsi256)
    check fill.renderOver(content, cpAnsi256).count(fill.sgr(cpAnsi256)) == 3

  test "identical to render when the content carries no reset":
    check fill.renderOver("hi", cpAnsi256) == fill.render("hi", cpAnsi256)

  test "an empty container is a no-op, reset in the content or not":
    let content = inner.render("hi", cpAnsi256)
    check Style().renderOver(content, cpAnsi256) == content
    check Style().renderOver("hi", cpAnsi256) == "hi"

  test "a colour-only container is a no-op under cpNoColor":
    # `sgr` returns "" rather than "\e[m" there, so there is nothing to re-arm —
    # and re-arming a bare reset would be worse than not styling at all.
    let content = inner.render("hi", cpNoColor)
    check fill.renderOver(content, cpNoColor) == content

  test "each line is still wrapped separately so backgrounds cannot smear":
    let content = inner.render("a", cpAnsi256) & "\n" & inner.render("b", cpAnsi256)
    let over = fill.renderOver(content, cpAnsi256)
    check over.splitLines.len == 2
    for line in over.splitLines:
      check line.startsWith(fill.sgr(cpAnsi256))
      check line.endsWith(Reset)

  test "re-arming costs no columns":
    let content = inner.render("hi", cpAnsi256) & "     "
    check displayWidth(fill.renderOver(content, cpAnsi256)) == 7

suite "colour profiles":
  # Every case here goes through the explicit `sgr(s, profile)` overload rather
  # than setting the module-level one. That is the convention for this file: the
  # bytes asserted above are exact, and a test that left a profile set — or that
  # depended on the `$TERM` of whoever ran the suite — would make them a matter
  # of luck.

  test "truecolour is the default, so nothing above depends on the environment":
    check colorProfile() == cpTrueColor

  test "256 colours approximates a truecolour value":
    # 255,128,0 lands on cube level (5, 2, 0) -> 16 + 36*5 + 6*2 + 0.
    check Style().fg(rgb(255, 128, 0)).sgr(cpAnsi256) == "\e[38;5;208m"

  test "a palette index is left alone under 256 colours":
    check Style().fg(ansiColor(196)).sgr(cpAnsi256) == "\e[38;5;196m"

  test "sixteen colours use whole parameters, not the extended form":
    check Style().fg(rgb(255, 0, 0)).sgr(cpAnsi16) == "\e[91m"
    check Style().bg(rgb(255, 0, 0)).sgr(cpAnsi16) == "\e[101m"
    check Style().fg(ansiColor(3)).sgr(cpAnsi16) == "\e[33m"
    check Style().bg(ansiColor(3)).sgr(cpAnsi16) == "\e[43m"

  test "a 256-colour index degrades too":
    check Style().fg(ansiColor(196)).sgr(cpAnsi16) == "\e[91m"

  test "no colour keeps the attributes":
    # `NO_COLOR` is about colour. Dropping the attributes with it would take the
    # reverse-video block TextInput draws its cursor with, which is worse than
    # the colour the user asked to be rid of.
    check Style().bold().fg(rgb(1, 2, 3)).sgr(cpNoColor) == "\e[1m"
    check Style().underline().bg(ansiColor(4)).sgr(cpNoColor) == "\e[4m"

  test "a style that is only colour emits nothing rather than a bare reset":
    # `"\e[m"` is a valid SGR meaning reset, so emitting one here would wrap the
    # text in a reset and leave `spans.render` re-arming it.
    check Style().fg(rgb(1, 2, 3)).bg(ansiColor(4)).sgr(cpNoColor) == ""
    check Style().fg(rgb(1, 2, 3)).render("x", cpNoColor) == "x"

  test "an unknown colour is unaffected by any profile":
    for p in ColorProfile:
      check Style().bold().sgr(p) == "\e[1m"

  test "attributes and a colour still order the same way":
    check Style().bold().fg(ansiColor(1)).bg(ansiColor(2)).sgr(cpAnsi16) ==
      "\e[1;31;42m"

suite "profile detection":
  test "NO_COLOR wins over everything":
    check profileFor("1", "truecolor", "xterm-256color") == cpNoColor

  test "an empty NO_COLOR is not a request":
    check profileFor("", "truecolor", "xterm-256color") == cpTrueColor

  test "COLORTERM declares truecolour even under a 256-colour TERM":
    # The tmux case: TERM is screen-256color there whatever the outer terminal is.
    check profileFor("", "truecolor", "screen-256color") == cpTrueColor
    check profileFor("", "24bit", "screen-256color") == cpTrueColor

  test "a 256-colour TERM is taken at its word":
    check profileFor("", "", "xterm-256color") == cpAnsi256

  test "a dumb or absent terminal gets no colour":
    check profileFor("", "", "dumb") == cpNoColor
    check profileFor("", "", "") == cpNoColor

  test "the linux console gets sixteen":
    check profileFor("", "", "linux") == cpAnsi16

  test "an unknown TERM is guessed at 256 rather than none":
    check profileFor("", "", "xterm") == cpAnsi256
