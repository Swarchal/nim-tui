import std/[unittest, strutils, unicode]
import nimtui/[ansi, style, color, textarea]

## Two things go wrong in a scrolling pane and both are silent. The window can
## drift out of step with the content, which shows up as a blank pane or a
## missing last line; and the wrapped form can go stale after a resize, which
## shows up as lines wider than the pane — and a line wider than its pane
## desynchronises the whole frame, not just that line.

proc paragraph(n: int): string =
  var parts: seq[string]
  for i in 0 ..< n: parts.add "line " & $i
  parts.join("\n")

suite "textarea geometry":
  test "render is exactly width x height, gutter included":
    var ta = initTextArea(width = 20, height = 6)
    ta.setText paragraph(30)
    let ls = ta.render().split('\n')
    check ls.len == 6
    for line in ls:
      check displayWidth(line) == 20

  test "geometry holds when the content is shorter than the pane":
    var ta = initTextArea(width = 20, height = 10)
    ta.setText "one\ntwo"
    let ls = ta.render().split('\n')
    check ls.len == 10
    for line in ls:
      check displayWidth(line) == 20

  test "geometry holds with no content at all":
    var ta = initTextArea(width = 16, height = 4)
    for line in ta.render().split('\n'):
      check displayWidth(line) == 16

  test "a degenerate size renders nothing rather than a broken block":
    check initTextArea(width = 0, height = 5).render() == ""
    check initTextArea(width = 10, height = 0).render() == ""

  test "double-width text still fits the pane exactly":
    var ta = initTextArea(width = 15, height = 5)
    ta.setText "日本語のテキストがここにあります"
    for line in ta.render().split('\n'):
      check displayWidth(line) == 15

  test "styled text is measured by its visible width":
    var ta = initTextArea(width = 24, height = 3)
    ta.setText Style().fg(hex"#f85149").bold().render("an error happened here")
    for line in ta.render().split('\n'):
      check displayWidth(line) == 24

suite "textarea wrapping":
  test "long lines wrap and blank lines survive":
    var ta = initTextArea(width = 11, height = 10, showScrollbar = false)
    ta.setText "aaa bbb ccc ddd\n\nzzz"
    check ta.lineCount == 4              # two wrapped rows, a blank, and zzz
    check ta.lines.len == 3              # the source is untouched

  test "turning wrapping off leaves the source lines alone":
    var ta = initTextArea(width = 10, height = 5, wrap = false)
    ta.setText paragraph(3) & "\na very long line that will not be wrapped"
    check ta.lineCount == 4

  test "resizing re-wraps, and a same-width resize does not have to":
    var ta = initTextArea(width = 40, height = 5)
    ta.setText "aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll"
    let wide = ta.lineCount
    ta.resize(12, 5)
    check ta.lineCount > wide
    for line in ta.render().split('\n'):
      check displayWidth(line) == 12

  test "appending wraps only the new line":
    var ta = initTextArea(width = 11, height = 5, showScrollbar = false)
    ta.setText "short"
    check ta.lineCount == 1
    ta.add "aaa bbb ccc ddd"
    check ta.lineCount == 3
    check ta.lines.len == 2

suite "textarea scrolling":
  test "scrolling stays inside the content":
    var ta = initTextArea(width = 20, height = 5)
    ta.setText paragraph(20)
    ta.scrollBy(-100)
    check ta.vp.top == 0
    check ta.atTop
    ta.scrollBy(1000)
    check ta.vp.top == 15                # last page, not past the end
    check ta.atBottom

  test "a pane larger than its content cannot scroll":
    var ta = initTextArea(width = 20, height = 20)
    ta.setText paragraph(3)
    ta.scrollBy(10)
    check ta.vp.top == 0
    check ta.atTop
    check ta.atBottom

  test "paging keeps a line of context":
    var ta = initTextArea(width = 20, height = 10, showScrollbar = false)
    ta.setText paragraph(100)
    ta.pageDown()
    check ta.vp.top == 9
    ta.pageUp()
    check ta.vp.top == 0

  test "home and end reach both extremes":
    var ta = initTextArea(width = 20, height = 5)
    ta.setText paragraph(50)
    ta.toBottom()
    check ta.vp.top == 45
    ta.toTop()
    check ta.vp.top == 0

suite "textarea follow":
  test "following pins the pane to the tail as lines arrive":
    var ta = initTextArea(width = 20, height = 5, follow = true)
    for i in 0 ..< 50: ta.add "line " & $i
    check ta.atBottom
    check ta.render().contains("line 49")

  test "scrolling up stops the pane following":
    # The classic log-viewer bug: scroll up to read something and the next
    # arriving line yanks you back to the bottom.
    var ta = initTextArea(width = 20, height = 5, follow = true)
    for i in 0 ..< 50: ta.add "line " & $i
    ta.scrollBy(-10)
    check not ta.follow
    let before = ta.vp.top
    ta.add "line 50"
    check ta.vp.top == before
    check not ta.render().contains("line 50")

  test "scrolling back to the bottom resumes following":
    var ta = initTextArea(width = 20, height = 5, follow = true)
    for i in 0 ..< 50: ta.add "line " & $i
    ta.scrollBy(-10)
    check not ta.follow
    ta.scrollBy(10)
    check ta.follow
    ta.add "line 50"
    check ta.render().contains("line 50")

  test "not following leaves the view where it was":
    var ta = initTextArea(width = 20, height = 5)
    for i in 0 ..< 50: ta.add "line " & $i
    check ta.vp.top == 0

suite "textarea keys":
  test "navigation keys are consumed and others are not":
    var ta = initTextArea(width = 20, height = 5)
    ta.setText paragraph(50)
    check ta.handleKey(KeyMsg(key: kDown))
    check ta.vp.top == 1
    check ta.handleKey(KeyMsg(key: kEnd))
    check ta.atBottom
    check not ta.handleKey(KeyMsg(key: kEnter))
    check not ta.handleKey(KeyMsg(key: kRune, rune: "q".runeAt(0)))

  test "horizontal keys belong to the application when wrapping is on":
    var wrapped = initTextArea(width = 20, height = 5)
    wrapped.setText paragraph(5)
    check not wrapped.handleKey(KeyMsg(key: kRight))
    var flat = initTextArea(width = 20, height = 5, wrap = false)
    flat.setText paragraph(5)
    check flat.handleKey(KeyMsg(key: kRight))
    check flat.xOffset == 1

  test "horizontal scrolling keeps the pane exactly as wide":
    var ta = initTextArea(width = 12, height = 3, wrap = false)
    ta.setText "abcdefghijklmnopqrstuvwxyz"
    for x in 0 .. 20:
      ta.xOffset = x
      for line in ta.render().split('\n'):
        check displayWidth(line) == 12

suite "textarea position label":
  test "the label reports where the pane is":
    var ta = initTextArea(width = 20, height = 5)
    ta.setText paragraph(3)
    check ta.positionLabel == "all"
    ta.setText paragraph(100)
    check ta.positionLabel == "top"
    ta.toBottom()
    check ta.positionLabel == "bot"
    ta.scrollBy(-40)
    check ta.positionLabel.endsWith("%")

suite "textarea line style":
  ## A pager's content is the pre-styled case by definition — a diff, a
  ## colourised log — so `lineStyle` has to be the floor those escapes fall back
  ## to rather than something the first of them cancels.
  test "lineStyle survives a reset in the text":
    let ls = Style().bg(ansiColor(4))
    var ta = initTextArea(width = 20, height = 3)
    ta.lineStyle = ls
    ta.setText Style().bold().render("hi") & " there"
    let pane = ta.render()
    check (Reset & ls.sgr()) in pane
    for line in pane.split('\n'):
      check displayWidth(line) == 20

suite "textarea flattening":
  ## A pager is pointed at *files*, and a file is where a tab is not an edge
  ## case. `runeWidth` measures one as zero columns and the terminal draws it as
  ## a jump, so a pane holding one pads a line to what it believes is the full
  ## width and the terminal puts it over the edge — clipped rather than wrapped,
  ## since auto-wrap is off, which is why the symptom was a file shown with its
  ## indentation wrong rather than a frame falling apart. Every dimensional
  ## assertion above agrees the line is the right width, which is exactly why
  ## this went unnoticed.

  test "a tab is expanded, not drawn":
    var ta = initTextArea(width = 20, height = 3, showScrollbar = false)
    ta.setText "a\tb"
    let pane = ta.render()
    check '\t' notin pane
    check pane.split('\n')[0] == "a       b           "

  test "and the pane is as wide as the terminal will draw it":
    # The assertion the rest of this file makes, on the input that used to pass
    # it while being wrong: `displayWidth` said 20 because the tab counted zero.
    for w in [8, 12, 20, 40]:
      for src in ["a\tb", "\tindented", "日\tx", "no tabs here", "a\t\tb"]:
        checkpoint $w & " " & escape(src)
        var ta = initTextArea(width = w, height = 2, wrap = false,
                              showScrollbar = false)
        ta.setText src
        for line in ta.render().split('\n'):
          check displayWidth(line) == w
          check '\t' notin line

  test "the other control characters go too":
    var ta = initTextArea(width = 20, height = 2, showScrollbar = false)
    # A newline reaching `lines` as part of one entry would make the pane one
    # row taller than it says it is.
    ta.setLines @["one\ntwo"]
    check ta.render().split('\n').len == 2

  test "tabStop is a preference and zero is the terminal's default":
    var ta = initTextArea(width = 20, height = 1, showScrollbar = false)
    ta.setText "a\tb"
    check ta.wrappedLines[0] == "a       b"     # 0 means 8
    ta.tabStop = 4
    ta.reflow()
    check ta.wrappedLines[0] == "a   b"

  test "wrapping measures the expanded line":
    # A tab counted as zero columns fits under any width, so an unexpanded line
    # never wraps and comes out over-wide instead.
    var ta = initTextArea(width = 12, height = 6, showScrollbar = false)
    ta.setText "\tindented text that has to wrap"
    check ta.lineCount > 1
    for line in ta.render().split('\n'):
      check displayWidth(line) == 12

  test "reflow is the boundary, so a direct write to lines is covered":
    # The module's one escape hatch — write `lines`, then `reflow` — must not be
    # the way round it.
    var ta = initTextArea(width = 20, height = 2, showScrollbar = false)
    ta.lines = @["x\ty"]
    ta.reflow()
    check '\t' notin ta.render()

  test "add takes the same path as setText":
    var ta = initTextArea(width = 20, height = 3, showScrollbar = false)
    ta.add "a\tb"
    ta.add ""
    check ta.wrappedLines[0] == "a       b"
    check ta.wrappedLines[1] == ""

  test "text with nothing to flatten is untouched":
    var ta = initTextArea(width = 20, height = 4, showScrollbar = false)
    let src = @["plain", "日本語", "\e[31mred\e[0m"]
    ta.setLines src
    check ta.wrappedLines == src
