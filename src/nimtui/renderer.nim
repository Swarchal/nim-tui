## Line-oriented "standard" renderer.
##
## The view is a plain string. On each frame the renderer walks the cursor back
## over the block it drew last time and rewrites only the lines that differ.
## That keeps the terminal's own scrollback intact when not using the alternate
## screen, and needs no cell buffer.
##
## Three consequences worth knowing:
##
## * Frames are skipped when identical to the previous one, and unchanged lines
##   within a frame are skipped individually, so `render` is cheap to call in a
##   tight loop.
## * Cursor arithmetic assumes no line wraps, so lines are truncated to `width`
##   and the frame is clipped to `height`.
## * The bytes for one frame are wrapped in synchronized-output markers, so a
##   terminal that supports them shows the frame all at once.

import std/strutils
import ./ansi

type
  LineSpan = tuple[a, b: int]
    ## Byte range `frame[a ..< b]` of one line of a view.

  Renderer* = object
    output*: File
    width*, height*: int      ## 0 disables truncation / clipping
    lastFrame: string         ## the view string `lastSpans` points into
    lastSpans: seq[LineSpan]  ## where each tracked line sits in `lastFrame`
    lastLines: seq[string]    ## the lines believed to be on screen, as emitted

proc initRenderer*(output: File, width = 0, height = 0): Renderer =
  Renderer(output: output, width: width, height: height)

proc lineSpans(r: Renderer, frame: string): seq[LineSpan] =
  ## Byte ranges of the view's lines, clipped to `height`.
  ##
  ## Deliberately not `frame.split('\n')`: that allocates a string per line on
  ## every frame, and both the comparison against the previous frame and the
  ## decision to truncate can be made on the bytes where they already are.
  result = newSeqOfCap[LineSpan](if r.height > 0: r.height else: 32)
  var start = 0
  while r.height <= 0 or result.len < r.height:
    let nl = frame.find('\n', start)
    if nl < 0:
      result.add (start, frame.len)
      break
    result.add (start, nl)
    start = nl + 1

proc sameLine(a: string, ar: LineSpan, b: string, br: LineSpan): bool =
  ## Whether two line spans hold the same bytes, without materialising either as
  ## a string. A byte-at-a-time loop here would cost more than the `split` this
  ## exists to avoid, so it compares in bulk.
  let n = ar.b - ar.a
  if n != br.b - br.a: return false
  if n == 0: return true
  equalMem(unsafeAddr a[ar.a], unsafeAddr b[br.a], n)

proc lastRenderedHeight*(r: Renderer): int =
  ## Number of lines currently on screen. Useful in tests.
  r.lastLines.len

proc forgetScreen(r: var Renderer) =
  ## Drop everything believed about the screen, so the next frame is drawn in
  ## full. One place, so the three callers cannot drift apart if the tracked
  ## state grows another field — `lastSpans` indexes into `lastFrame` and is
  ## meaningless without it, so they must always be cleared together.
  r.lastFrame = ""
  r.lastSpans.setLen 0
  r.lastLines.setLen 0

proc buildFrame(r: var Renderer, frame: string): string =
  ## Emit the bytes for `frame` and update the tracked state to match.
  ##
  ## The one implementation behind both `render` and `frameFor`, so the bytes the
  ## tests assert cannot drift from the bytes sent to the terminal.
  if frame == r.lastFrame: return ""
  let spans = r.lineSpans(frame)
  let prevLen = r.lastLines.len
  result = newStringOfCap(frame.len + 64)
  result.add BeginSyncUpdate
  if prevLen > 1:
    result.add cursorUp(prevLen - 1)
  result.add "\r"
  if spans.len > prevLen:
    # Grow up front so the loop can assign in place. New slots hold "", which is
    # never mistaken for a tracked line because `i >= prevLen` is checked first.
    r.lastLines.setLen spans.len
  for i in 0 ..< spans.len:
    # Compare the raw bytes before truncating. Truncation is the expensive step
    # and an unchanged line needs none of it, so on a view where one line moves
    # this skips ~97% of the work. Same bytes and same width give the same
    # truncation, and a width change goes through `repaint`, which drops all of
    # this state — so reusing the previous emitted line here is exact.
    #
    # `lastSpans` and `lastLines` are always the same length, but bounds-check
    # both: relying on one to index the other would turn any future slip between
    # them into an out-of-bounds read rather than a redraw.
    let unchanged = i < prevLen and i < r.lastSpans.len and
                    sameLine(frame, spans[i], r.lastFrame, r.lastSpans[i])
    if not unchanged:
      var raw = frame[spans[i].a ..< spans[i].b]
      var line = if r.width > 0: truncateVisible(raw, r.width) else: move(raw)
      if i >= prevLen or r.lastLines[i] != line:
        # Content first, then erase the tail. Erasing before writing leaves the
        # line momentarily blank, which a terminal refreshing on its own clock
        # mid-frame will happily show — that is what reads as flicker.
        result.add line
        result.add Reset         # so an unreset style cannot colour the erase
        result.add EraseLineRight
      # Moved, not assigned: a plain assignment copies the string, which on a
      # full repaint is one copy per line. Nothing reads `line` after this.
      r.lastLines[i] = move(line)
    if i < spans.high:
      result.add "\r\n"
  if prevLen > spans.len:
    # The frame shrank: blank the leftover lines, then come back up.
    let extra = prevLen - spans.len
    for _ in 1 .. extra:
      result.add "\r\n"
      result.add Reset
      result.add EraseLine
    result.add cursorUp(extra)
    r.lastLines.setLen spans.len
  result.add "\r"
  result.add EndSyncUpdate
  # Order matters: the spans index into this frame, so both must be stored, and
  # `lastFrame` must not be overwritten before the loop above has read it.
  r.lastSpans = spans
  r.lastFrame = frame

proc frameFor*(r: Renderer, frame: string): string =
  ## The exact bytes `render` would emit for `frame`, without writing them or
  ## disturbing the renderer.
  ##
  ## Split out so the cursor arithmetic can be asserted without a terminal. It
  ## copies the tracked state in order to run the real code path rather than a
  ## parallel one, which makes it dearer than `render` — fine for tests, but not
  ## something to call per frame.
  var probe = r
  probe.buildFrame(frame)

proc render*(r: var Renderer, frame: string) =
  ## Draw `frame`, rewriting only the lines that differ from what is already on
  ## screen and doing nothing at all if the whole frame matches.
  let data = r.buildFrame(frame)
  if data.len == 0: return
  r.output.write data
  r.output.flushFile()

proc repaint*(r: var Renderer) =
  ## Forget what is on screen so the next `render` redraws unconditionally.
  ##
  ## The next frame is drawn from wherever the cursor happens to be, so the
  ## caller is responsible for clearing whatever was there — see `clearBlock`,
  ## or clear the screen outright if the program owns it.
  r.forgetScreen()

proc clearBlockFor*(r: Renderer): string =
  ## The exact bytes `clearBlock` would emit. Split out for the same reason as
  ## `frameFor`: so the cursor arithmetic can be asserted without a terminal.
  if r.lastLines.len == 0: return ""
  result = newStringOfCap(32)
  if r.lastLines.len > 1:
    result.add cursorUp(r.lastLines.len - 1)
  result.add "\r"
  result.add Reset        # so the erase cannot be painted in a stale background
  result.add EraseDown

proc clearBlock*(r: var Renderer) =
  ## Erase the block currently on screen, leaving the cursor on its first line
  ## so the next frame is drawn from the same origin.
  ##
  ## For use after a resize: the tracked line contents no longer describe the
  ## screen, but the block still has to be cleaned up before it is redrawn, or
  ## the old frame stays behind under the new one. Exact for a height change; if
  ## the width shrank enough for the old lines to have wrapped, the walk up
  ## falls short by however many rows wrapped, since the renderer's arithmetic
  ## assumes no wrapping. A program that owns the whole screen should clear the
  ## screen instead, which has no such caveat.
  let data = r.clearBlockFor()
  if data.len > 0:
    r.output.write data
    r.output.flushFile()
  r.forgetScreen()

proc finish*(r: var Renderer) =
  ## Move below the rendered block and clear it, leaving the cursor on a fresh
  ## line ready for the shell prompt.
  if r.lastLines.len > 0:
    r.output.write "\r\n"
    r.output.flushFile()
  r.forgetScreen()
