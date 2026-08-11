import std/[unittest, unicode, strutils, random]
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

  test "a truncated rune does not stall the buffer after a timeout":
    # Found by the fuzz suite at the bottom of this file, and it is the `ESC`
    # `[` `q` stall in a different place: the read has timed out, so the rest of
    # the rune is never coming, and returning "nothing yet" forever means the
    # buffer never empties and the next key pressed is silently swallowed.
    #
    # One byte, not the whole partial sequence — the same rule a flushed escape
    # follows, and for the same reason: everything after it is real input.
    let lead = "\xF3"                            # a 4-byte lead with nothing after
    check parseInput(lead).consumed == 0         # still held while more may come
    check parseInput(lead, flushEsc = true).consumed == 1
    check parseInput(lead, flushEsc = true).msgs.len == 0
    check keys(lead & "ab", flushEsc = true) == @["a", "b"]

  test "a byte that cannot be a continuation is malformed now, not later":
    # `\xF3` wants three continuation bytes and an ESC is not one, so this is
    # already broken and no amount of waiting fixes it. Holding anyway would
    # keep a perfectly good arrow key hostage behind a bad byte until the read
    # timed out — and the whole point of not consuming eagerly is to protect
    # real input, which this was doing the opposite of.
    check keys("\xF3\e[A") == @["up"]
    check parseInput("\xF3\e[A").consumed == 4
    check keys("\xC3ab") == @["a", "b"]           # 2-byte lead, `a` is not a tail
    # A genuine prefix is still held, since those bytes really may be coming.
    check parseInput("\xE6\x97").consumed == 0     # first two bytes of 日
    check keys("\xE6\x97\xA5") == @["日"]

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

suite "bracketed paste":
  # What this exists for: without mode 2004 a pasted newline is `kEnter`, so
  # pasting two lines into a text field submits the first one halfway through the
  # paste, moves focus, or opens whatever was selected. The markers make the
  # difference visible; these tests are about the decoder not throwing it away.

  proc pastes(s: string, flushEsc = false, flushPaste = false): seq[string] =
    let (msgs, _) = parseInput(s, flushEsc, flushPaste)
    for m in msgs:
      if m of PasteMsg: result.add PasteMsg(m).text

  proc typed(s: string, flushEsc = false, flushPaste = false): seq[string] =
    ## The keys only — not the `keys` helper above, which requires every message
    ## to be a key, when the point here is that a paste is not one.
    let (msgs, _) = parseInput(s, flushEsc, flushPaste)
    for m in msgs:
      if m of KeyMsg: result.add $KeyMsg(m)

  test "a paste is one message and no keys":
    let s = "\e[200~hello\e[201~"
    let (msgs, consumed) = parseInput(s)
    check consumed == s.len
    require msgs.len == 1
    check PasteMsg(msgs[0]).text == "hello"
    check typed(s).len == 0

  test "a pasted newline is text, not the enter key":
    # The bug this whole thing is for.
    check pastes("\e[200~a\nb\e[201~") == @["a\nb"]
    check "enter" notin typed("\e[200~a\nb\e[201~")
    check pastes("\e[200~a\r\nb\tc\e[201~") == @["a\r\nb\tc"]

  test "an escape inside a paste is payload, not the end of it":
    # The deliberate divergence from the string-sequence scan: a paste payload is
    # user data, and pasted captures and configs contain escapes routinely.
    check pastes("\e[200~a\e[Ab\e[201~") == @["a\e[Ab"]
    check typed("\e[200~a\e[Ab\e[201~").len == 0

  test "a paste among keys leaves the keys alone and in order":
    check typed("x\e[200~pasted\e[201~y") == @["x", "y"]
    check pastes("x\e[200~pasted\e[201~y") == @["pasted"]

  test "an empty paste is still a paste":
    check pastes("\e[200~\e[201~") == @[""]

  test "an unterminated paste is held even once the read has timed out":
    # The inversion. Every other partial sequence resolves on a flush; a read
    # timing out in the middle of a real paste is ordinary, so this one must not.
    let (msgs, consumed) = parseInput("\e[200~abc", flushEsc = true)
    check msgs.len == 0
    check consumed == 0

  test "a paste split across two reads decodes once whole":
    var buf = "\e[200~part one"
    var (msgs, consumed) = parseInput(buf)
    check msgs.len == 0
    check consumed == 0
    buf.add " and part two\e[201~"
    (msgs, consumed) = parseInput(buf)
    require msgs.len == 1
    check PasteMsg(msgs[0]).text == "part one and part two"
    check consumed == buf.len

  test "a stalled paste is delivered rather than held forever":
    # A literally typed start marker with nothing behind it never grows, so no
    # byte cap can reach it — without this it would hold the buffer for the life
    # of the program and swallow whatever was typed next.
    let s = "\e[200~abc"
    let (msgs, consumed) = parseInput(s, flushPaste = true)
    require msgs.len == 1
    check PasteMsg(msgs[0]).text == "abc"
    check consumed == s.len
    check pastes("\e[200~", flushPaste = true) == @[""]

  test "a stalled paste hands the buffer back, so keys after it still decode":
    var buf = "\e[200~abc"
    let (_, consumed) = parseInput(buf, flushPaste = true)
    buf = buf[consumed .. ^1]
    check buf.len == 0
    check keys("q") == @["q"]

  test "an oversized paste is delivered rather than held":
    var payload = newString(MaxPasteBytes + 1)
    for i in 0 ..< payload.len: payload[i] = 'x'
    let s = "\e[200~" & payload
    let (msgs, consumed) = parseInput(s)
    require msgs.len == 1
    check PasteMsg(msgs[0]).text.len == MaxPasteBytes + 1
    check consumed == s.len

  test "a stray end marker is consumed and dropped":
    let (msgs, consumed) = parseInput("\e[201~")
    check msgs.len == 0
    check consumed == 6
    check typed("\e[201~q") == @["q"]

  test "the start marker only fires once it is complete":
    # A partial one is an ordinary partial CSI and behaves as it always did.
    check parseInput("\e[200").consumed == 0
    check keys("\e[200", flushEsc = true) == @["esc", "[", "2", "0", "0"]

  test "holdsPaste tells a held paste from a held escape sequence":
    check "\e[200~abc".holdsPaste
    check not "\e[".holdsPaste
    check not "".holdsPaste
    check not "abc".holdsPaste

suite "focus events":
  proc focuses(s: string): seq[bool] =
    let (msgs, _) = parseInput(s)
    for m in msgs:
      if m of FocusMsg: result.add FocusMsg(m).focused

  proc typed(s: string): seq[string] =
    let (msgs, _) = parseInput(s)
    for m in msgs:
      if m of KeyMsg: result.add $KeyMsg(m)

  test "focus in and focus out are distinguishable":
    check focuses("\e[I") == @[true]
    check focuses("\e[O") == @[false]

  test "and are not keys":
    check typed("\e[I\e[O").len == 0
    let (msgs, consumed) = parseInput("\e[I")
    check msgs.len == 1
    check consumed == 3

  test "they arrive among keys without disturbing them":
    check typed("a\e[Ib\e[Oc") == @["a", "b", "c"]
    check focuses("a\e[Ib\e[Oc") == @[true, false]

  test "only the bare form is a focus event":
    # `CSI I` is the whole sequence. A parameterised sequence ending in the same
    # byte is something else, and calling it a focus change would be a lie.
    check focuses("\e[1I").len == 0
    check focuses("\e[5;2O").len == 0
    check parseInput("\e[1I").consumed == 4      # still consumed, just not reported

  test "a private marker is parameterisation too":
    # It does not land in `params`, being parsed out ahead of them — so guarding
    # on `params.len` alone let `\e[?I` through as a focus event.
    for private in "<?>=":
      check focuses("\e[" & private & "I").len == 0
      check focuses("\e[" & private & "O").len == 0
      check parseInput("\e[" & private & "I").consumed == 4

  test "a split one is held until it is whole":
    var buf = "\e["
    check parseInput(buf).consumed == 0
    buf.add "I"
    check focuses(buf) == @[true]

suite "streams" :
  test "a burst of pasted text decodes in order":
    check keys("hi\r\e[A") == @["h", "i", "enter", "up"]

# --- what the decoder promises, over every input rather than chosen ones -------
#
# Everything above is a case somebody thought of. These two suites are the two
# properties those cases are all instances of, checked mechanically: the split
# rule over every cut point of a corpus, and the progress rule over random
# bytes. Both exist because the failure mode here is bytes that are not
# keystrokes arriving as keystrokes, and the cases that produce it are the ones
# nobody sat down and wrote.

proc describe(m: Msg): string =
  ## Every message the decoder can emit, as a comparable string.
  if m of KeyMsg: "key " & $KeyMsg(m)
  elif m of MouseMsg:
    let e = MouseMsg(m)
    "mouse " & $e.button & " " & $e.action & " " & $e.x & "," & $e.y & " " & $e.mods
  elif m of PasteMsg: "paste " & PasteMsg(m).text
  elif m of OscMsg: "osc " & OscMsg(m).payload
  elif m of FocusMsg: "focus " & $FocusMsg(m).focused
  else: "unknown message type"

proc whole(data: string): tuple[msgs: seq[string], consumed: int] =
  let (msgs, n) = parseInput(data)
  for m in msgs: result.msgs.add describe(m)
  result.consumed = n

proc inChunks(data: string, cuts: varargs[int]):
    tuple[msgs: seq[string], consumed: int] =
  ## Feed `data` in pieces the way `program.run` does: append what arrived to
  ## what was left over, parse, keep the remainder.
  var
    buf = ""
    pos = 0
  for cut in @cuts & @[data.len]:
    if cut < pos or cut > data.len: continue
    buf.add data[pos ..< cut]
    pos = cut
    let (msgs, n) = parseInput(buf)
    for m in msgs: result.msgs.add describe(m)
    buf = buf[n .. ^1]
    result.consumed += n

const Corpus = [
  # Plain text, including runes whose bytes can be cut in the middle.
  "abc", "é", "日本語", "a日b",
  # C0 and the named keys.
  "\r\n\t\x7f\x03", "\0",
  # Escape sequences of every shape the decoder knows.
  "\e[A", "\eOA", "\e[3~", "\e[1;5C", "\e[Z", "\ea", "\e\e", "\e",
  # Unrecognised but well-formed, which is consumed and dropped.
  "\e[q", "\e[?1049h",
  # Mouse, both encodings. An X10 report's three bytes are arbitrary and can
  # include an ESC, which is exactly the sort of thing a split finds.
  "\e[<0;12;34M", "\e[<64;1;1M", "\e[M\x20\x21\x22", "\e[M\x1b\x21\x22",
  # Focus, bare and parameterised.
  "\e[I", "\e[O", "\e[1I", "\e[?I",
  # String sequences: payload to a terminator, either terminator.
  "\e]11;rgb:1e1e/1e1e/1e1e\e\\", "\e]0;title\a", "\ePtmux;\e\e[A\e\\",
  "\e_apc\e\\", "\e^pm\e\\", "\eXsos\e\\",
  # An ESC inside a string sequence that is not ST ends it where it stands.
  "\e]11;\e[A",
  # Paste: payload is user data, so an ESC in it is payload.
  "\e[200~hello\e[201~", "\e[200~a\e[Ab\e[201~", "\e[200~\e[200~\e[201~",
  "\e[201~", "\e[200~unterminated",
  # Partial everything, which must stay unconsumed rather than half-decoded.
  "\e[", "\e[1;", "\eO", "\e[<0;12", "\e[M\x20", "\e]11;rgb", "\e[200~",
  # Mixtures, which is what a real read looks like.
  "a\e[Ab", "hi\r\e[A", "\e[A\e]0;t\a\e[B", "x\e[200~p\e[201~y",
  "\e[<0;1;1M\e[<0;1;1m", "ab\e[", "\e[Iabc\e[O",
]

suite "split invariance":
  ## **However the bytes are chopped up, the answer is the same.** A read
  ## returns whatever has arrived, not one event, so every sequence here can
  ## arrive in pieces — routinely, over ssh or through tmux. Every hand-written
  ## case in this file is one instance of this property; the loop below is all
  ## of them.
  ##
  ## `flushEsc` is deliberately off throughout. It exists precisely to make the
  ## answer depend on *timing* rather than only on bytes — a lone ESC is the
  ## Escape key or the start of an arrow depending on whether more is coming —
  ## so with it on the two sides are not supposed to agree.

  test "one cut anywhere makes no difference":
    for data in Corpus:
      let want = whole(data)
      for cut in 0 .. data.len:
        checkpoint escape(data) & " cut at " & $cut
        let got = inChunks(data, cut)
        check got.msgs == want.msgs
        check got.consumed == want.consumed

  test "two cuts anywhere make no difference either":
    # A byte at a time is the worst case and the one a slow link produces.
    for data in Corpus:
      let want = whole(data)
      for a in 0 .. data.len:
        for b in a .. data.len:
          checkpoint escape(data) & " cut at " & $a & "," & $b
          let got = inChunks(data, a, b)
          check got.msgs == want.msgs
          check got.consumed == want.consumed

  test "a byte at a time is the same as all at once":
    for data in Corpus:
      var cuts: seq[int]
      for i in 0 .. data.len: cuts.add i
      checkpoint escape(data)
      let got = inChunks(data, cuts)
      let want = whole(data)
      check got.msgs == want.msgs
      check got.consumed == want.consumed

  test "and so is a pair of sequences run together":
    # Concatenation is where a decoder that consumes one byte too many or too
    # few stops being invisible: the damage lands in the *next* event.
    for a in Corpus:
      for b in Corpus:
        let data = a & b
        checkpoint escape(data)
        let want = whole(data)
        check inChunks(data, a.len).msgs == want.msgs
        check inChunks(data, a.len).consumed == want.consumed

const Interesting = "\e[]O~;<>?=Mm 0123456789ab\a\\\x7f\r\n\x03"
  ## The bytes that mean something to the decoder. Uniformly random bytes are
  ## almost never escape-shaped, so a fuzzer without this spends its entire run
  ## on the printable-rune path and proves nothing about the parts that hold
  ## state.

proc fuzz(r: var Rand, n: int): string =
  for _ in 0 ..< n:
    if r.rand(1.0) < 0.75: result.add Interesting[r.rand(Interesting.high)]
    else: result.add char(r.rand(255))

suite "progress on arbitrary bytes":
  ## The decoder is a pure function from a string to messages, so there is no
  ## reason not to throw rubbish at it. Three things have to hold for *any*
  ## input, and each of them is a bug that has actually happened here or is one
  ## slip away.
  ##
  ## A fixed seed, deliberately: a fuzz failure nobody can reproduce is worse
  ## than no fuzz test, and this is a regression suite rather than a search.

  const Seed = 0x6e696d747569'i64      # "nimtui"
  const Samples = 3000

  test "it never claims more bytes than it was given":
    # An over-consuming decoder makes the caller slice past the end of its own
    # buffer, which loses input that had already arrived.
    var r = initRand(Seed)
    for _ in 0 ..< Samples:
      let s = fuzz(r, r.rand(1 .. 24))
      for esc in [false, true]:
        for paste in [false, true]:
          let (_, n) = parseInput(s, esc, paste)
          checkpoint escape(s) & " esc=" & $esc & " paste=" & $paste
          check n >= 0
          check n <= s.len

  test "a timed-out read always makes progress, unless it is holding a paste":
    # *The* stall property, and the one with a real bug behind it: `ESC` `[` `q`
    # used to return "nothing yet" forever, so the buffer never emptied and the
    # decoder silently swallowed whichever key was pressed next.
    #
    # The exception is not slack. A paste is held across an escape flush on
    # purpose — an escape sequence that has paused for 50ms is over, a paste
    # that has paused for 50ms is completely ordinary — so consuming nothing
    # there is the documented behaviour rather than the bug.
    var r = initRand(Seed + 1)
    for _ in 0 ..< Samples:
      let s = fuzz(r, r.rand(1 .. 24))
      let (_, n) = parseInput(s, flushEsc = true)
      checkpoint escape(s)
      if s.holdsPaste():
        check n == 0
      else:
        check n >= 1

  test "and with the paste flush too, there is no exception at all":
    # Both timeouts expired is the caller's last resort, and after it the buffer
    # must always shrink — there is nothing left that waiting could resolve.
    var r = initRand(Seed + 2)
    for _ in 0 ..< Samples:
      let s = "\e[200~" & fuzz(r, r.rand(0 .. 20))
      checkpoint escape(s)
      let (_, n) = parseInput(s, flushEsc = true, flushPaste = true)
      check n >= 1

  test "draining always terminates":
    # The property the loop in `program.run` actually depends on: hand it a
    # buffer and keep slicing, and it empties. The guard is what turns an
    # unbounded loop into a failed assertion rather than a hung suite.
    var r = initRand(Seed + 3)
    for _ in 0 ..< Samples:
      var buf = fuzz(r, r.rand(1 .. 32))
      checkpoint escape(buf)
      var guard = buf.len + 2
      while buf.len > 0:
        let (_, n) = parseInput(buf, flushEsc = true, flushPaste = true)
        check n >= 1
        if n < 1: break
        buf = buf[n .. ^1]
        dec guard
        check guard > 0
        if guard <= 0: break

  test "no input makes it raise":
    var r = initRand(Seed + 4)
    for _ in 0 ..< Samples:
      let s = fuzz(r, r.rand(0 .. 40))
      checkpoint escape(s)
      try:
        for esc in [false, true]:
          for paste in [false, true]:
            discard parseInput(s, esc, paste)
      except CatchableError as e:
        check "no exception" == e.msg

  test "and a random tail after a real sequence changes nothing in front of it":
    # Where a decoder that mis-measures one sequence does its damage: in the
    # next one. The messages from the prefix must not depend on the rubbish.
    var r = initRand(Seed + 5)
    for data in Corpus:
      let want = whole(data)
      if want.consumed < data.len: continue   # a partial prefix absorbs the tail
      for _ in 0 .. 20:
        let s = data & fuzz(r, r.rand(1 .. 8))
        checkpoint escape(s)
        let got = whole(s)
        check got.msgs.len >= want.msgs.len
        check got.msgs[0 ..< want.msgs.len] == want.msgs
