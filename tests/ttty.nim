import std/[unittest, strutils]
import nimtui/[ansi, tty]

## The bytes that put the terminal back, asserted without a terminal.
##
## The handler that writes them cannot be tested here — it ends the process —
## and `tests/manual/signals.py` covers that half under a pty. What is testable
## is the sequence itself, split out of the writing for the same reason
## `renderer.frameFor` is split out of `render`.

const AllModes = {TerminalMode.low .. TerminalMode.high}
  ## Written as the whole range rather than listed, so a mode added later is
  ## covered by the size and containment assertions below without anyone
  ## remembering to add it here.

suite "restoring the terminal":
  test "modes that were never enabled are not turned off":
    check restoreEscapesFor({}) == ""

  test "each mode contributes its own escape and nothing else":
    check restoreEscapesFor({tmAltScreen}) == ExitAltScreen
    check restoreEscapesFor({tmLineWrap}) == EnableLineWrap
    check restoreEscapesFor({tmHideCursor}) == ShowCursor
    check restoreEscapesFor({tmMouse}) == DisableMouse
    check restoreEscapesFor({tmBracketedPaste}) == DisableBracketedPaste
    check restoreEscapesFor({tmFocus}) == DisableFocusReporting

  test "auto-wrap goes back on before the alt screen is left":
    # The reverse of the order `setupTerminal` sets them in. Both halves matter:
    # the mode is put back on the buffer it was cleared on, and a shell that
    # inherits a terminal with auto-wrap off is nearly as broken as one that
    # inherits it without ECHO.
    let s = restoreEscapesFor({tmAltScreen, tmLineWrap})
    check s.find(EnableLineWrap) >= 0
    check s.find(EnableLineWrap) < s.find(ExitAltScreen)

  test "every mode contributes something, so none is silently forgotten":
    for m in TerminalMode:
      checkpoint $m
      check restoreEscapesFor({m}).len > 0

  test "the normal path leaves the newline to the renderer":
    # Only the renderer knows whether a block is on screen to move past.
    check "\r\n" notin restoreEscapesFor(AllModes)
    check "\n" notin restoreEscapesFor(AllModes - {tmAltScreen})

suite "mouse tracking levels":
  ## `tmMouse` covers all three levels with one escape, which is the only reason
  ## adding `mtClicks` needed nothing in `restoreEscapesFor`. That holds because
  ## `DisableMouse` turns off every private mode the three enables turn on — an
  ## arithmetic fact about four constants, and the thing that quietly stops being
  ## true the moment a fourth level is added.

  test "each level turns on the SGR encoding, which is what 1006 is":
    for on in [EnableMouse, EnableMouseCellMotion, EnableMouseAllMotion]:
      checkpoint escape(on)
      check "?1006h" in on

  test "the three levels are distinct":
    check EnableMouse != EnableMouseCellMotion
    check EnableMouseCellMotion != EnableMouseAllMotion
    check EnableMouse != EnableMouseAllMotion

  test "one teardown undoes whichever level was on":
    # Every `?<n>h` in any of the three has its `?<n>l` in DisableMouse. A level
    # added without extending DisableMouse leaves the terminal reporting into the
    # shell, which is the failure `tmMouse` exists to prevent.
    for on in [EnableMouse, EnableMouseCellMotion, EnableMouseAllMotion]:
      for part in on.split(Csi):
        if part.len == 0: continue
        checkpoint escape(on) & " sets " & part
        check part.endsWith("h")
        check Csi & part[0 ..< part.high] & "l" in DisableMouse

suite "emergency restore bytes":
  test "synchronised output is ended first, since a signal can land mid-frame":
    # A frame is wrapped in BeginSyncUpdate/EndSyncUpdate, and a terminal left
    # holding its display looks exactly like a hang.
    check emergencyEscapesFor(AllModes).startsWith(EndSyncUpdate)
    check emergencyEscapesFor({}).startsWith(EndSyncUpdate)

  test "colour is always reset, which the normal path need not do":
    # A signal can land between the escape that turns a colour on and the one
    # that turns it off; on the normal path `style.render` has emitted both.
    check Reset in emergencyEscapesFor({})

  test "a program on the alt screen leaves it rather than printing a newline":
    let s = emergencyEscapesFor({tmAltScreen})
    check ExitAltScreen in s
    check not s.endsWith("\r\n")

  test "a program in the scrollback ends on a fresh line":
    check emergencyEscapesFor({}).endsWith("\r\n")
    check emergencyEscapesFor(AllModes - {tmAltScreen}).endsWith("\r\n")

  test "it does everything the normal path does":
    for modes in [{}, AllModes, {tmHideCursor, tmBracketedPaste},
                  {tmAltScreen, tmMouse}, {tmFocus}]:
      checkpoint $modes
      check restoreEscapesFor(modes) in emergencyEscapesFor(modes)

  test "the longest sequence fits the buffer a handler can write from":
    # The one that fails if someone lengthens DisableMouse, rather than the
    # handler silently emitting half of it.
    check emergencyEscapesFor(AllModes).len <= MaxRestoreBytes
