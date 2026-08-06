import std/[unittest, strutils]
import nimtui/[ansi, tty]

## The bytes that put the terminal back, asserted without a terminal.
##
## The handler that writes them cannot be tested here — it ends the process —
## and `tests/manual/signals.py` covers that half under a pty. What is testable
## is the sequence itself, split out of the writing for the same reason
## `renderer.frameFor` is split out of `render`.

suite "restoring the terminal":
  test "modes that were never enabled are not turned off":
    check restoreEscapesFor(false, false, false, false) == ""

  test "each mode contributes its own escape and nothing else":
    check restoreEscapesFor(true, false, false, false) == ExitAltScreen
    check restoreEscapesFor(false, true, false, false) == ShowCursor
    check restoreEscapesFor(false, false, true, false) == DisableMouse
    check restoreEscapesFor(false, false, false, true) == DisableBracketedPaste

  test "the normal path leaves the newline to the renderer":
    # Only the renderer knows whether a block is on screen to move past.
    check "\r\n" notin restoreEscapesFor(true, true, true, true)
    check "\n" notin restoreEscapesFor(false, true, true, true)

suite "emergency restore bytes":
  test "synchronised output is ended first, since a signal can land mid-frame":
    # A frame is wrapped in BeginSyncUpdate/EndSyncUpdate, and a terminal left
    # holding its display looks exactly like a hang.
    check emergencyEscapesFor(true, true, true, true).startsWith(EndSyncUpdate)
    check emergencyEscapesFor(false, false, false, false).startsWith(EndSyncUpdate)

  test "colour is always reset, which the normal path need not do":
    # A signal can land between the escape that turns a colour on and the one
    # that turns it off; on the normal path `style.render` has emitted both.
    check Reset in emergencyEscapesFor(false, false, false, false)

  test "a program on the alt screen leaves it rather than printing a newline":
    let s = emergencyEscapesFor(true, false, false, false)
    check ExitAltScreen in s
    check not s.endsWith("\r\n")

  test "a program in the scrollback ends on a fresh line":
    check emergencyEscapesFor(false, false, false, false).endsWith("\r\n")
    check emergencyEscapesFor(false, true, true, true).endsWith("\r\n")

  test "it does everything the normal path does":
    let modes = [(false, false, false, false), (true, true, true, true),
                 (false, true, false, true), (true, false, true, false)]
    for (a, h, m, b) in modes:
      checkpoint $(a, h, m, b)
      check restoreEscapesFor(a, h, m, b) in emergencyEscapesFor(a, h, m, b)

  test "the longest sequence fits the buffer a handler can write from":
    # The one that fails if someone lengthens DisableMouse, rather than the
    # handler silently emitting half of it.
    check emergencyEscapesFor(true, true, true, true).len <= MaxRestoreBytes
