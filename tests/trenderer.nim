import std/[unittest, strutils]
import nimtui/[ansi, renderer]

## `frameFor` returns exactly the bytes `render` would write, so the cursor
## arithmetic can be asserted without a terminal. `render` itself is driven with
## its output pointed at /dev/null, purely to advance the renderer's state.

var sink: File
require sink.open("/dev/null", fmWrite)

proc newTestRenderer(width = 0, height = 0): Renderer =
  initRenderer(sink, width, height)

proc framed(body: string): string =
  ## The envelope every non-empty frame carries: synchronized-output markers
  ## around the whole frame, and a trailing CR to park the cursor at column 1.
  BeginSyncUpdate & body & "\r" & EndSyncUpdate

proc drawn(line: string): string =
  ## One line the renderer chose to rewrite: content, then erase to end of line.
  line & Reset & EraseLineRight

suite "first frame":
  test "writes each line and does not move the cursor up":
    var r = newTestRenderer()
    check r.frameFor("hello") == framed("\r" & drawn("hello"))

  test "multi-line frames use CR LF because raw mode disables OPOST":
    var r = newTestRenderer()
    check r.frameFor("a\nb") == framed("\r" & drawn("a") & "\r\n" & drawn("b"))

suite "redraw":
  test "walks the cursor back over the previous block":
    var r = newTestRenderer()
    r.render "a\nb\nc"
    check r.lastRenderedHeight == 3
    check r.frameFor("x\ny\nz").startsWith(BeginSyncUpdate & cursorUp(2))

  test "identical frames emit nothing":
    var r = newTestRenderer()
    r.render "same"
    check r.frameFor("same") == ""

  test "unchanged lines are skipped, not rewritten":
    var r = newTestRenderer()
    r.render "a\nb\nc"
    # Only the middle line differs, so only it is written: the cursor moves over
    # the other two. This is what stops a one-line change repainting the screen.
    check r.frameFor("a\nX\nc") ==
      framed(cursorUp(2) & "\r" & "\r\n" & drawn("X") & "\r\n")

  test "an unchanged line is left alone even when its neighbours move":
    var r = newTestRenderer()
    r.render "keep\nold"
    let data = r.frameFor("keep\nnew")
    check data.contains(drawn("new"))
    check not data.contains("keep")

  test "shrinking frames blank the leftover lines and return":
    var r = newTestRenderer()
    r.render "a\nb\nc"
    let data = r.frameFor("only")
    check data.startsWith(BeginSyncUpdate & cursorUp(2))
    check data.contains("\r\n" & Reset & EraseLine)   # blanking pass
    check data.endsWith(cursorUp(2) & "\r" & EndSyncUpdate)  # …then back up two
    r.render "only"
    check r.lastRenderedHeight == 1

  test "growing frames need no blanking pass":
    var r = newTestRenderer()
    r.render "a"
    check r.frameFor("a\nb\nc") ==
      framed("\r" & "\r\n" & drawn("b") & "\r\n" & drawn("c"))

suite "line structure":
  ## The renderer tracks lines as byte ranges into the previous frame rather than
  ## as copies, so the boundaries of that arithmetic need holding down: a
  ## trailing newline puts a line's start at exactly `frame.len`.
  test "a trailing newline is a final empty line":
    var r = newTestRenderer()
    r.render "a\n"
    check r.lastRenderedHeight == 2
    check r.frameFor("a\n") == ""          # spans describe it, so a repeat is a no-op

  test "frames made only of newlines":
    var r = newTestRenderer()
    r.render "\n\n"
    check r.lastRenderedHeight == 3
    check r.frameFor("\n\n") == ""

  test "a line appearing after the tracked end is drawn":
    var r = newTestRenderer()
    r.render "one\ntwo\n"
    check r.lastRenderedHeight == 3
    let data = r.frameFor("one\ntwo\nthree")
    check data.contains(drawn("three"))
    check not data.contains("one")

  test "growing a frame by appending to its last line":
    var r = newTestRenderer()
    r.render "one\ntwo"
    check r.frameFor("one\ntwoo") ==
      framed(cursorUp(1) & "\r" & "\r\n" & drawn("twoo"))

  test "a line changing length shorter is still erased to the end":
    var r = newTestRenderer()
    r.render "one\nlonger line"
    # The tail of the old, longer line must go; that is what EraseLineRight does.
    check r.frameFor("one\nshort") ==
      framed(cursorUp(1) & "\r" & "\r\n" & drawn("short"))

suite "synchronized output":
  test "every emitted frame is wrapped in begin/end markers":
    var r = newTestRenderer()
    let first = r.frameFor("hello")
    check first.startsWith(BeginSyncUpdate)
    check first.endsWith(EndSyncUpdate)
    check first.count(BeginSyncUpdate) == 1
    check first.count(EndSyncUpdate) == 1

  test "a skipped frame emits no markers either":
    var r = newTestRenderer()
    r.render "hello"
    check r.frameFor("hello") == ""

suite "clipping":
  test "lines are truncated to the terminal width":
    var r = newTestRenderer(width = 4)
    check r.frameFor("abcdefgh") == framed("\r" & drawn("abcd"))

  test "styling survives truncation":
    var r = newTestRenderer(width = 3)
    let visible = stripAnsi(r.frameFor("\e[31mabcdef\e[0m"))
    check visible.contains("abc")
    check not visible.contains("abcd")

  test "frames taller than the terminal are clipped":
    var r = newTestRenderer(height = 2)
    r.render "a\nb\nc\nd"
    check r.lastRenderedHeight == 2

suite "state":
  test "repaint forces a redraw of an unchanged frame":
    var r = newTestRenderer()
    r.render "hello"
    check r.frameFor("hello") == ""
    r.repaint()
    check r.frameFor("hello") != ""
    check r.lastRenderedHeight == 0

  test "repaint redraws every line, not just changed ones":
    var r = newTestRenderer()
    r.render "a\nb"
    r.repaint()
    # After a resize the screen contents are unknown, so nothing may be skipped.
    check r.frameFor("a\nb") == framed("\r" & drawn("a") & "\r\n" & drawn("b"))

  test "clearBlock walks up to the block's first line and erases downward":
    var r = newTestRenderer()
    r.render "a\nb\nc"
    check r.clearBlockFor() == cursorUp(2) & "\r" & Reset & EraseDown
    r.clearBlock()
    check r.lastRenderedHeight == 0

  test "clearBlock on a single line does not move the cursor up":
    var r = newTestRenderer()
    r.render "only"
    check r.clearBlockFor() == "\r" & Reset & EraseDown

  test "clearBlock with nothing on screen emits nothing":
    var r = newTestRenderer()
    check r.clearBlockFor() == ""

  test "the frame after clearBlock is drawn in full":
    var r = newTestRenderer()
    r.render "a\nb"
    r.clearBlock()
    # The screen was just wiped, so skipping a line would leave it blank.
    check r.frameFor("a\nb") == framed("\r" & drawn("a") & "\r\n" & drawn("b"))

  test "finish clears the tracked block":
    var r = newTestRenderer()
    r.render "hello"
    r.finish()
    check r.lastRenderedHeight == 0
    check r.frameFor("hello") != ""

sink.close()
