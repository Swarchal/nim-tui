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
