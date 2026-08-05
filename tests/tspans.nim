import std/[unittest, strutils]
import nimtui/[ansi, style, color, spans]

## A `Spans` exists so a multi-coloured line can be measured and cut as one
## thing. The assertions that matter are therefore the same dimensional ones the
## rest of the library lives by — the visible width must survive styling — plus
## the guarantee that cutting never lands inside a colour.

const Red = hex"#f85149"
const Blue = hex"#58a6ff"

suite "spans building":
  test "empty runs are dropped rather than stored":
    var s: Spans
    s.add("")
    s.add("x")
    s.add("")
    check s.items.len == 1
    check s.isEmpty == false
    check Spans().isEmpty

  test "concatenation keeps runs in order":
    let s = span("a", Style().fg(Red)) & span("b", Style().fg(Blue)) & "c"
    check s.text == "abc"
    check s.items.len == 3
    check ("x" & span("y")).text == "xy"

suite "spans measurement":
  test "width ignores escapes and counts columns":
    var s: Spans
    s.add("ERROR ", Style().fg(Red).bold())
    s.add("timeout")
    check s.displayWidth == 13
    check s.text == "ERROR timeout"
    # The rendered string measures the same, which is the property the layout
    # helpers depend on.
    check displayWidth(s.render()) == 13

  test "double-width runs measure two columns each":
    let s = span("日本", Style().fg(Red)) & span("ab")
    check s.displayWidth == 6
    check displayWidth(s.render()) == 6

suite "spans cutting":
  test "truncate is exact and drops whole runs past the cut":
    var s: Spans
    s.add("abcde", Style().fg(Red))
    s.add("fghij", Style().fg(Blue))
    check s.truncate(3).text == "abc"
    check s.truncate(7).text == "abcdefg"
    check s.truncate(20).text == "abcdefghij"
    check s.truncate(0).isEmpty
    for w in 1 .. 12:
      check s.truncate(w).displayWidth == min(w, 10)

  test "a cut inside a wide rune becomes a space, keeping the width exact":
    let s = span("日本語", Style().fg(Red))
    check s.truncate(3).displayWidth == 3
    check s.truncate(3).text == "日 "
    check s.truncate(4).text == "日本"

  test "the run a cut lands in keeps its own style":
    var s: Spans
    s.add("abc", Style().fg(Red))
    s.add("defgh", Style().fg(Blue))
    let cut = s.truncate(5)
    check cut.items.len == 2
    check cut.items[1].style.fgc == Blue
    check cut.items[1].text == "de"

  test "pad reaches the width and never shrinks":
    let s = span("abc")
    for w in [0, 3, 10, 40]:
      check s.pad(w).displayWidth == max(w, 3)
    check s.pad(7, align = aRight).text == "    abc"
    check s.pad(7, align = aCenter).text == "  abc  "
    check s.pad(8, align = aCenter).text == "  abc   "   # odd remainder to the right

  test "fit is exact in both directions":
    var s: Spans
    s.add("hello", Style().fg(Red))
    s.add(" world")
    for w in 1 .. 20:
      check s.fit(w).displayWidth == w

  test "elide marks a cut line and stays within the width":
    let s = span("abcdefghij", Style().fg(Red))
    check s.elide(5).text == "abcd…"
    check s.elide(5).displayWidth == 5
    check s.elide(20).text == "abcdefghij"          # short enough, left alone
    check s.elide(1).displayWidth == 1

suite "spans rendering":
  test "an empty style emits no escape at all":
    check span("plain").render() == "plain"

  test "adjacent runs sharing a style share one escape pair":
    var s: Spans
    for i in 0 ..< 10: s.add("x", Style().fg(Red))
    let r = s.render()
    check r.count("\e[") == 2                        # one on, one reset
    check r.stripAnsi == "xxxxxxxxxx"

  test "differing runs each get their own":
    var s: Spans
    s.add("a", Style().fg(Red))
    s.add("b", Style().fg(Blue))
    check s.render().count("\e[") == 4
    check s.render().stripAnsi == "ab"

  test "a run's style survives a reset the text brought with it":
    # Text that is already styled — a table cell the caller coloured — ends its
    # own styling with a reset, which clears the run's background as well. The
    # run has to be re-armed after it, or the fill stops at that point and the
    # rest of the run is a hole.
    let bg = Style().bg(Blue)
    var s: Spans
    s.add(Style().fg(Red).render("WARN") & "   ", bg)
    let r = s.render()
    check r.stripAnsi == "WARN   "
    check r.endsWith(Reset)
    # The three spaces after the inner reset are painted, not bare.
    check (Reset & bg.sgr() & "   ") in r

  test "an unstyled run is left exactly as it arrived":
    # Nothing to re-arm, and nothing to copy: the guard is what keeps text with
    # escapes in it from being rewritten when the run adds no style of its own.
    let text = Style().fg(Red).render("WARN") & "   "
    check span(text).render() == text

suite "gradient text":
  test "the visible text and width are unchanged":
    let g = gradient(Red, Blue)
    for text in ["nimtui", "a", "日本語テキスト", ""]:
      let ramped = gradientText(text, g)
      check ramped.stripAnsi == text
      check displayWidth(ramped) == displayWidth(text)

  test "the ramp runs over columns, so it reaches both ends":
    let g = gradient(hex"#000000", hex"#ffffff")
    let s = gradientSpans("abcdefghij", g)
    check s.items[0].style.fgc == hex"#000000"
    check s.items[^1].style.fgc == hex"#ffffff"

  test "an existing escape passes through without advancing the ramp":
    # A caller's own styling occupies no columns and must not consume part of
    # the gradient, or the colours bunch up wherever it appears.
    let g = gradient(hex"#000000", hex"#ffffff")
    let styled = "ab" & Reset & "cd"
    let s = gradientSpans(styled, g)
    check s.text.stripAnsi == "abcd"
    check displayWidth(s.render()) == 4

  test "an empty gradient leaves the text alone":
    check gradientText("abc", Gradient()) == "abc"

  test "background mode ramps the background instead":
    let s = gradientSpans("ab", gradient(Red, Blue), background = true)
    check s.items[0].style.bgc == Red
    check s.items[0].style.fgc.kind == ckDefault

  test "the base style's attributes survive on every run":
    let s = gradientSpans("abc", gradient(Red, Blue), Style().bold())
    for item in s.items:
      check aBold in item.style.attrs

suite "a Spans is a line":
  ## The module claims it in its first paragraph; these are the assertions that
  ## make the claim true rather than aspirational. The reason it has to be true
  ## here, on the way in, is that flattening is not width-preserving — so a
  ## `Spans` that measured one thing and rendered another would put the
  ## discrepancy inside every helper that had already fitted it to a column.

  test "a run cannot carry a line break":
    var line: Spans
    line.add("first\nsecond")
    check '\n' notin line.render()
    check '\n' notin line.text
    check line.text == "first second"

  test "nor can the one-run constructor":
    check '\n' notin span("a\nb").render()
    check span("a\nb").text == "a b"

  test "what it measures is what it renders":
    # The property everything downstream rests on. Measured before flattening,
    # "a\nb" is two columns and draws as three across two lines.
    for s in ["a\nb", "x\ty\rz", "log:\n  at main()", "日\n本"]:
      var line: Spans
      line.add(s)
      checkpoint s
      check line.displayWidth == displayWidth(line.render())
      check line.render().split('\n').len == 1

  test "fitting to a width still hits it exactly":
    for w in 1 .. 12:
      var line: Spans
      line.add("one\ntwo\nthree")
      check displayWidth(line.fit(w).render()) == w

  test "styling survives the flattening":
    var line: Spans
    line.add("a\nb", Style().fg(hex"#ff0000"))
    let rendered = line.render()
    check '\n' notin rendered
    check rendered.stripAnsi == "a b"
    check rendered.startsWith(Style().fg(hex"#ff0000").sgr)

  test "a gradient run is flattened too":
    # `gradientSpans` builds its runs directly rather than through `add`, so it is
    # the one path that could still produce a span holding a break.
    let g = gradientSpans("up\ndown", CoolGradient)
    check '\n' notin g.render()
    check g.text == "up down"
    check g.displayWidth == 7
