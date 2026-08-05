import std/[unittest, unicode]
import nimtui/[messages, input]

proc keys(s: string, flushEsc = false): seq[string] =
  ## Decode `s` and describe each key with `$KeyMsg`.
  let (msgs, _) = parseInput(s, flushEsc)
  for m in msgs:
    check m of KeyMsg
    result.add $KeyMsg(m)

proc one(s: string): KeyMsg =
  let (msgs, _) = parseInput(s, flushEsc = true)
  require msgs.len == 1
  require msgs[0] of KeyMsg
  KeyMsg(msgs[0])

suite "printable input":
  test "ascii runes":
    check keys("abc") == @["a", "b", "c"]
    let k = one("a")
    check k.key == kRune
    check k.rune == Rune('a')
    check k.mods == {}

  test "utf-8 runes decode as single keys":
    check keys("é") == @["é"]
    check keys("日本") == @["日", "本"]

  test "space is its own key but carries the rune":
    let k = one(" ")
    check k.key == kSpace
    check k.rune == Rune(' ')

suite "control characters":
  test "ctrl letters":
    check keys("\x03") == @["ctrl+c"]
    check keys("\x01") == @["ctrl+a"]
    check keys("\x1a") == @["ctrl+z"]

  test "the well-known control codes get named keys":
    check keys("\r") == @["enter"]
    check keys("\n") == @["enter"]
    check keys("\t") == @["tab"]
    check keys("\x7f") == @["backspace"]
    check keys("\b") == @["backspace"]

  test "ctrl+space":
    let k = one("\0")
    check k.key == kSpace
    check k.mods == {mCtrl}

suite "escape sequences":
  test "arrow keys":
    check keys("\e[A") == @["up"]
    check keys("\e[B") == @["down"]
    check keys("\e[C") == @["right"]
    check keys("\e[D") == @["left"]

  test "ss3 form arrows and function keys":
    check keys("\eOA") == @["up"]
    check keys("\eOP") == @["f1"]
    check keys("\eOS") == @["f4"]

  test "navigation keys":
    check keys("\e[H") == @["home"]
    check keys("\e[F") == @["end"]
    check keys("\e[3~") == @["delete"]
    check keys("\e[2~") == @["insert"]
    check keys("\e[5~") == @["pgup"]
    check keys("\e[6~") == @["pgdown"]

  test "function keys in CSI form":
    check keys("\e[15~") == @["f5"]
    check keys("\e[24~") == @["f12"]

  test "shift+tab":
    check keys("\e[Z") == @["shift+tab"]

  test "xterm modifiers":
    check keys("\e[1;5A") == @["ctrl+up"]
    check keys("\e[1;2D") == @["shift+left"]
    check keys("\e[1;3B") == @["alt+down"]
    check keys("\e[1;7C") == @["ctrl+alt+right"]
    check keys("\e[5;5~") == @["ctrl+pgup"]

  test "alt is reported as ESC prefix":
    check keys("\ea") == @["alt+a"]
    check keys("\e\r") == @["alt+enter"]

  test "unrecognised but well-formed sequences are dropped":
    let (msgs, consumed) = parseInput("\e[99q")
    check msgs.len == 0
    check consumed == 5

suite "escape ambiguity":
  test "a lone ESC is held until the read times out":
    let held = parseInput("\e")
    check held.msgs.len == 0
    check held.consumed == 0
    let flushed = parseInput("\e", flushEsc = true)
    check flushed.msgs.len == 1
    check $KeyMsg(flushed.msgs[0]) == "esc"

  test "double ESC yields the escape key immediately":
    check keys("\e\e") == @["esc"]

  test "an incomplete sequence flushes to Escape without eating the next key":
    # Held while the rest of the sequence might still be in flight...
    check parseInput("\e[").consumed == 0
    # ...but once the read has timed out the rest is never coming. Report the ESC
    # alone and consume only that byte, so what follows decodes as ordinary keys.
    # Consuming the whole partial sequence instead would swallow them: the buffer
    # stalled indefinitely and then absorbed whatever arrived next, which for
    # `ESC [ q` meant losing the `q` — the quit key in every example.
    check keys("\e[", flushEsc = true) == @["esc", "["]
    check parseInput("\e[", flushEsc = true).consumed == 2
    check keys("\e[1;", flushEsc = true) == @["esc", "[", "1", ";"]
    check keys("\eO", flushEsc = true) == @["esc", "O"]
    check keys("\e[M", flushEsc = true) == @["esc", "[", "M"]

  test "flushing does not disturb a sequence that is complete":
    check keys("\e[A", flushEsc = true) == @["up"]
    check keys("\eOP", flushEsc = true) == @["f1"]
    check keys("\ea", flushEsc = true) == @["alt+a"]

suite "partial sequences" :
  test "an incomplete CSI is not consumed":
    let r = parseInput("\e[1;")
    check r.msgs.len == 0
    check r.consumed == 0

  test "a split rune is not consumed":
    let whole = "é"
    let r = parseInput(whole[0 ..< 1])
    check r.msgs.len == 0
    check r.consumed == 0

  test "complete events before a partial one are consumed":
    let r = parseInput("ab\e[")
    check r.msgs.len == 2
    check r.consumed == 2

  test "resuming with the remainder works":
    var buf = "\e["
    var got: seq[string]
    for m in parseInput(buf).msgs: got.add $KeyMsg(m)
    check got.len == 0
    buf.add "A"
    let r = parseInput(buf)
    check r.consumed == 3
    check $KeyMsg(r.msgs[0]) == "up"

suite "mouse":
  test "SGR press and release":
    let (msgs, consumed) = parseInput("\e[<0;12;34M")
    require msgs.len == 1
    require msgs[0] of MouseMsg
    let m = MouseMsg(msgs[0])
    check consumed == 11
    check (m.x, m.y) == (12, 34)
    check m.button == mbLeft
    check m.action == maPress

    let up = MouseMsg(parseInput("\e[<0;12;34m").msgs[0])
    check up.action == maRelease

  test "wheel and motion":
    check MouseMsg(parseInput("\e[<64;1;1M").msgs[0]).button == mbWheelUp
    check MouseMsg(parseInput("\e[<65;1;1M").msgs[0]).button == mbWheelDown
    check MouseMsg(parseInput("\e[<32;5;5M").msgs[0]).action == maMotion

  test "modifiers":
    let m = MouseMsg(parseInput("\e[<16;1;1M").msgs[0])
    check m.mods == {mCtrl}

  test "X10 reports are swallowed whole":
    let r = parseInput("\e[M\x20\x21\x22")
    check r.msgs.len == 0
    check r.consumed == 6

suite "string sequences":
  # The bug this whole suite is about: with no branch for `ESC ]`, an OSC reply
  # fell through to the alt-modified path and arrived as alt+`]` followed by its
  # payload typed one rune at a time. A program that never asks the terminal
  # anything is not exempt — anything else sharing the terminal can ask, and the
  # answer comes back here.
  proc replies(s: string, flushEsc = false): seq[string] =
    let (msgs, _) = parseInput(s, flushEsc)
    for m in msgs:
      if m of OscMsg: result.add OscMsg(m).payload

  proc typed(s: string, flushEsc = false): seq[string] =
    ## The keys only. Not the `keys` helper above, which requires every message
    ## to be a key — here the point is that an OSC reply is not one.
    let (msgs, _) = parseInput(s, flushEsc)
    for m in msgs:
      if m of KeyMsg: result.add $KeyMsg(m)

  test "an OSC reply is one message and no keys":
    let bg = "\e]11;rgb:1e1e/1e1e/1e1e\e\\"
    let (msgs, consumed) = parseInput(bg)
    check consumed == bg.len
    require msgs.len == 1
    require msgs[0] of OscMsg
    check OscMsg(msgs[0]).payload == "11;rgb:1e1e/1e1e/1e1e"
    # The half that matters. Anything at all in a text field is the failure.
    check typed(bg).len == 0

  test "BEL terminates it too":
    check replies("\e]11;rgb:00/00/00\a") == @["11;rgb:00/00/00"]

  test "the terminator is not part of the payload":
    check replies("\e]0;a title\e\\") == @["0;a title"]

  test "a reply among keys leaves the keys alone and in order":
    let (msgs, _) = parseInput("a\e]11;rgb:ff/ff/ff\ab")
    check msgs.len == 3
    check typed("a\e]11;rgb:ff/ff/ff\ab") == @["a", "b"]
    check replies("a\e]11;rgb:ff/ff/ff\ab") == @["11;rgb:ff/ff/ff"]

  test "DCS, APC, PM and SOS are consumed but not reported":
    # Nothing here queries with them, so there is nothing to report — but the
    # bytes must still go, which is the same contract as an unrecognised CSI.
    for intro in ["P", "_", "^", "X"]:
      let s = "\e" & intro & "payload;1;2\e\\"
      let (msgs, consumed) = parseInput(s)
      checkpoint "ESC " & intro
      check msgs.len == 0
      check consumed == s.len

  test "an unterminated one is held, not typed":
    # Held while more bytes may still arrive: the payload can straddle two reads.
    let (msgs, consumed) = parseInput("\e]11;rgb:1e1e/1e")
    check msgs.len == 0
    check consumed == 0

  test "and is swallowed rather than typed once the read has timed out":
    # The deliberate departure from `flushEsc`'s usual rule. A truncated CSI
    # reports `ESC` and leaves the rest to decode as keys, because those bytes
    # might be real input; `11;rgb:1e` is not, and putting it in a text field is
    # the bug rather than a lesser one.
    let s = "\e]11;rgb:1e"
    let (msgs, consumed) = parseInput(s, flushEsc = true)
    check msgs.len == 0
    check consumed == s.len

  test "but a bare introducer on a timeout is still alt+that key":
    # Two bytes and then silence for the whole escape timeout is far more likely
    # someone pressing alt+] than a reply that stalled immediately.
    check typed("\e]", flushEsc = true) == @["alt+]"]
    check typed("\eP", flushEsc = true) == @["alt+P"]

  test "an escape inside one does not swallow the sequence after it":
    # An ESC that is not ST ends the string sequence where it stands, so a real
    # sequence starting inside a malformed one is still decoded.
    check typed("\e]11;rgb:\e[A") == @["up"]

  test "a reply split across two reads decodes once whole":
    # What the caller's retry loop does: keep the unconsumed bytes, ask again.
    var buf = "\e]11;rgb:2e34"
    var (msgs, consumed) = parseInput(buf)
    check msgs.len == 0
    check consumed == 0
    buf.add "/3436/4144\e\\"
    (msgs, consumed) = parseInput(buf)
    require msgs.len == 1
    check OscMsg(msgs[0]).payload == "11;rgb:2e34/3436/4144"
    check consumed == buf.len

suite "streams" :
  test "a burst of pasted text decodes in order":
    check keys("hi\r\e[A") == @["h", "i", "enter", "up"]
