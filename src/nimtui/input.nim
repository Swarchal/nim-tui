## Pure byte-stream to `Msg` decoding.
##
## The parser never reads from a file descriptor: callers hand it whatever bytes
## they have and get back the messages plus how many bytes were consumed. A
## partially received sequence is simply not consumed, so the caller keeps it
## and retries once more bytes arrive. This is what makes key handling testable
## without a terminal.

import std/[unicode, strutils]
import ./[ansi, messages]

const MaxPasteBytes* = 1 shl 20
  ## How much of an unterminated paste payload is held before it is given up on
  ## and delivered as it stands.
  ##
  ## A bound on the damage a forged or runaway start marker can do, not a limit
  ## on how much anyone may paste: truncating a legitimate paste would be the
  ## worse bug of the two, so this sits far above anything a human pastes through
  ## a terminal and far below anything that is a memory problem.
  ##
  ## It does not bound a *stalled* paste, and cannot — a start marker with
  ## nothing behind it produces no further bytes to hit any byte cap. That case
  ## is the caller's to time out; see `parseInput <#parseInput,string>`_.

proc decodeMods*(param: int): set[Modifier] =
  ## Decode an xterm modifier parameter (1 = none, 2 = shift, 5 = ctrl, ...).
  let m = param - 1
  if (m and 1) != 0: result.incl mShift
  if (m and 2) != 0: result.incl mAlt
  if (m and 4) != 0: result.incl mCtrl

proc utf8SeqLen(b: char): int =
  ## Expected byte length of a UTF-8 sequence from its leading byte, 0 if `b`
  ## cannot start one.
  let x = b.ord
  if x < 0x80: 1
  elif (x shr 5) == 0b110: 2
  elif (x shr 4) == 0b1110: 3
  elif (x shr 3) == 0b11110: 4
  else: 0

proc parseCsi(buf: string, start: int): tuple[msg: Msg, len: int] =
  ## Parse a CSI body. `start` indexes the byte after `ESC [`. The returned
  ## length is relative to `start`; 0 means "incomplete, wait for more bytes".
  var i = start
  var private = '\0'
  if i < buf.len and buf[i] in {'<', '?', '>', '='}:
    private = buf[i]
    inc i

  var params: seq[int]
  var cur = -1
  while i < buf.len and (buf[i] in {'0' .. '9', ';', ':'}):
    if buf[i] in {'0' .. '9'}:
      if cur < 0: cur = 0
      cur = cur * 10 + (buf[i].ord - '0'.ord)
    else:
      params.add(if cur < 0: 0 else: cur)
      cur = -1
    inc i
  if cur >= 0: params.add cur

  if i >= buf.len: return (nil, 0)
  let final = buf[i]
  let used = i - start + 1
  if not isFinalByte(final): return (nil, used)   # malformed: drop it

  proc param(n: int, dflt = 0): int =
    if n < params.len: params[n] else: dflt

  # SGR mouse reporting: ESC [ < button ; col ; row (M|m)
  if private == '<' and final in {'M', 'm'}:
    let b = param(0)
    var msg = MouseMsg(x: param(1, 1), y: param(2, 1))
    if (b and 4) != 0: msg.mods.incl mShift
    if (b and 8) != 0: msg.mods.incl mAlt
    if (b and 16) != 0: msg.mods.incl mCtrl
    if (b and 64) != 0:
      msg.action = maPress
      msg.button = if (b and 3) == 0: mbWheelUp else: mbWheelDown
    else:
      msg.action =
        if final == 'm': maRelease
        elif (b and 32) != 0: maMotion
        else: maPress
      msg.button = case b and 3
                   of 0: mbLeft
                   of 1: mbMiddle
                   of 2: mbRight
                   else: mbNone
    return (msg, used)

  # X10 mouse reporting is not decoded; swallow its three payload bytes so the
  # stream stays in sync.
  if private == '\0' and final == 'M':
    if start + used + 3 > buf.len: return (nil, 0)
    return (nil, used + 3)

  let mods = decodeMods(param(1, 1))

  template key(k: Key): tuple[msg: Msg, len: int] =
    (Msg(KeyMsg(key: k, mods: mods)), used)

  case final
  of 'A': return key(kUp)
  of 'B': return key(kDown)
  of 'C': return key(kRight)
  of 'D': return key(kLeft)
  of 'H': return key(kHome)
  of 'F': return key(kEnd)
  of 'Z': return (Msg(KeyMsg(key: kShiftTab, mods: {mShift})), used)
  of 'I', 'O':
    # Focus reporting, and only in the bare form: `CSI I` / `CSI O` are the whole
    # sequence. Guarding on that matters because a parameterised sequence ending
    # in the same final byte is something else entirely, and reporting it as a
    # focus change would be a lie rather than a gap.
    #
    # A private marker counts as parameterisation and does not land in `params` —
    # it is parsed out ahead of them, the same way the SGR mouse branch below
    # reads it — so `\e[?I` is as much not-a-focus-event as `\e[1I` is.
    if private != '\0' or params.len > 0: return (nil, used)
    return (Msg(FocusMsg(focused: final == 'I')), used)
  of 'P': return key(kF1)                       # some terminals in CSI form
  of 'Q': return key(kF2)
  of 'S': return key(kF4)
  of '~':
    let k = case param(0)
            of 1, 7: kHome
            of 2: kInsert
            of 3: kDelete
            of 4, 8: kEnd
            of 5: kPgUp
            of 6: kPgDown
            of 11: kF1
            of 12: kF2
            of 13: kF3
            of 14: kF4
            of 15: kF5
            of 17: kF6
            of 18: kF7
            of 19: kF8
            of 20: kF9
            of 21: kF10
            of 23: kF11
            of 24: kF12
            else: kNone
    if k == kNone: return (nil, used)
    # For `ESC [ 5 ; 3 ~` the modifier is the *second* parameter.
    return (Msg(KeyMsg(key: k, mods: decodeMods(param(1, 1)))), used)
  else:
    return (nil, used)                          # unrecognised but well-formed

proc parsePaste(buf: string, i: int, flushPaste: bool): tuple[msg: Msg, len: int] =
  ## `buf[i]` begins a complete `PasteStart`. Everything up to `PasteEnd` is
  ## payload, and the same three-state return applies.
  ##
  ## Note what does *not* end the scan: a bare `ESC`. That is the deliberate
  ## divergence from the string-sequence branch in `parseOne`, which treats one
  ## as a sequence started inside a malformed one — a reader will assume the two
  ## agree, and they must not. A string payload is protocol, so an `ESC` in it
  ## means something is wrong; a paste payload is *user data*, and pasted config
  ## files, terminal captures and shell scripts contain escapes as a matter of
  ## course. Only a literal `PasteEnd` ends a paste.
  var j = i + PasteStart.len
  while j + PasteEnd.len <= buf.len:
    # The `Esc` test first so the common byte costs a comparison rather than a
    # `continuesWith` call.
    if buf[j] == Esc and buf.continuesWith(PasteEnd, j):
      return (Msg(PasteMsg(text: buf[i + PasteStart.len ..< j])),
              j - i + PasteEnd.len)
    inc j

  # Off the end of the buffer with no terminator. Held whether or not the caller
  # flushed, which is the one place that reasoning inverts: every other partial
  # sequence is short and bounded, so a read timing out mid-sequence proves the
  # rest is never coming, while a paste payload is arbitrarily large and a read
  # timing out mid-payload — a slow link, tmux relaying a big buffer — is
  # ordinary. `flushEsc` is therefore not a parameter here at all.
  #
  # What does end the hold is `flushPaste`, which the caller raises once no byte
  # has arrived for a while, or the payload growing past `MaxPasteBytes`. Both
  # are needed: the byte cap bounds a runaway stream, and nothing but the
  # timeout bounds a stalled one — a literally typed `PasteStart` with nothing
  # behind it never grows, so it would otherwise be held forever and absorb
  # whatever was typed next, which is exactly the stall `flushEsc` exists to
  # prevent, reintroduced somewhere new.
  if flushPaste or buf.len - i - PasteStart.len > MaxPasteBytes:
    # Delivered as a paste rather than dropped or re-typed. Dropping silently
    # eats up to a megabyte of what may be real input; resolving to `ESC` and
    # letting the rest decode as keys — the rule everywhere else here — would
    # type the whole payload into whatever has focus, which is the precise
    # failure bracketed paste exists to prevent, amplified. A start marker with
    # an unterminated payload behind it is most likely a paste whose end marker
    # was lost, and a `PasteMsg` is the least destructive form those bytes can
    # take: a recipient inserts them, everyone else ignores them.
    #
    # One edge, since the bytes are taken as they lie: a buffer ending part way
    # through the terminator when the timeout fires puts those bytes in `text`.
    return (Msg(PasteMsg(text: buf[i + PasteStart.len ..< buf.len])), buf.len - i)
  (nil, 0)

proc parseOne(buf: string, i: int, flushEsc: bool, flushPaste: bool):
    tuple[msg: Msg, len: int] =
  ## Decode the single event starting at `buf[i]`.
  ##
  ## `len == 0` means the sequence is incomplete and nothing was consumed.
  ## A nil `msg` with `len > 0` means the bytes were recognised but carry no
  ## event worth reporting.
  let b = buf[i]

  # An escape sequence that runs off the end of the buffer. Held while more bytes
  # may still arrive; on a flush — the caller's read timed out, so the rest is
  # never coming — report the ESC alone and consume only that byte, leaving what
  # follows to be decoded as ordinary input. Without the flush the partial
  # sequence is held forever and then absorbs whatever key arrives next.
  template incomplete(): tuple[msg: Msg, len: int] =
    if flushEsc: (Msg(KeyMsg(key: kEsc)), 1) else: (nil, 0)

  if b == Esc:
    if i + 1 >= buf.len:
      # A lone ESC is ambiguous: it may be the start of a sequence still in
      # flight. Only the caller knows whether the read timed out.
      return incomplete()
    case buf[i + 1]
    of '[':
      # Both markers are checked before `parseCsi`, not inside it. `parseCsi`
      # reports lengths relative to the byte after `ESC [`, so it cannot express
      # "consume one byte, the ESC" — the flush contract has to be applied where
      # the `+ 2` is, which is here. And a paste is not CSI-shaped anyway: it is
      # an arbitrary-length payload ending at a terminator, the same shape as the
      # string sequences below, which is why it sits beside them.
      if buf.continuesWith(PasteStart, i):
        return parsePaste(buf, i, flushPaste)
      if buf.continuesWith(PasteEnd, i):
        # An end marker with no start: a paste this parser already gave up on, or
        # one whose beginning was lost. Consumed and dropped, which is what the
        # unrecognised-CSI path does with it today by accident — said out loud
        # here so adding `of 201:` to the `~` case cannot quietly change it.
        return (nil, PasteEnd.len)
      # A *partial* start marker is not recognised: `\e[200` falls through and is
      # held, or flushed to `esc` `[` `2` `0` `0`, exactly as before. The case
      # that misses — a terminal stalling inside the six-byte introducer — is not
      # one that happens, since a terminal emits the marker and some payload in
      # the same write.
      let (m, n) = parseCsi(buf, i + 2)
      return if n == 0: incomplete() else: (m, n + 2)
    of 'O':                                     # SS3: application cursor/function keys
      if i + 2 >= buf.len: return incomplete()
      let k = case buf[i + 2]
              of 'P': kF1
              of 'Q': kF2
              of 'R': kF3
              of 'S': kF4
              of 'A': kUp
              of 'B': kDown
              of 'C': kRight
              of 'D': kLeft
              of 'H': kHome
              of 'F': kEnd
              else: kNone
      return if k == kNone: (nil, 3) else: (Msg(KeyMsg(key: k)), 3)
    of StringIntroducers:
      # A string sequence — OSC, DCS, SOS, PM or APC — which is an *answer*, not
      # a keypress: the terminal replying to a query, its own or another
      # program's. Everything up to the terminator is payload.
      #
      # Decoded here because the alternative is not "ignored", it is typed. With
      # no branch for it, `ESC ]` fell to the alt-modified path below and an
      # OSC 11 reply arrived as alt+`]` followed by `1`, `1`, `;`, `r`, `g`, `b`
      # … as ordinary runes, straight into whatever had focus. An application
      # that never asks a question is not safe from this: anything else sharing
      # the terminal can ask, and the reply comes back on this stream.
      let kind = buf[i + 1]
      # Only OSC is reported. The other four are consumed and dropped — nothing
      # here queries with them, and a payload no one can interpret is worth
      # exactly as much as the bytes being gone, which is the same contract as an
      # unrecognised CSI.
      template answer(stop: int): Msg =
        if kind == ']': Msg(OscMsg(payload: buf[i + 2 ..< stop])) else: nil

      var j = i + 2
      while j < buf.len:
        if buf[j] == '\a':                      # BEL, the informal terminator
          return (answer(j), j - i + 1)
        if buf[j] == Esc:
          if j + 1 >= buf.len: break            # an ST that may still be in flight
          if buf[j + 1] == '\\':                # ST, the real one
            return (answer(j), j - i + 2)
          # An ESC that is not ST: the sequence is malformed, or a real one
          # started inside it. Consume what came before and leave the ESC to be
          # decoded next, rather than swallowing a keypress with it.
          return (nil, j - i)
        inc j

      # Off the end of the buffer with no terminator.
      if not flushEsc: return (nil, 0)
      if j == i + 2:
        # Nothing but the introducer, and the read has timed out: far more
        # likely alt+`]` than a reply that stalled after two bytes. Reported the
        # way the branch below would, since that is the behaviour this is
        # preserving.
        let (m, n) = parseOne(buf, i + 1, flushEsc, flushPaste)
        if n > 0 and m != nil and m of KeyMsg: KeyMsg(m).mods.incl mAlt
        return (m, n + 1)
      # A payload that will never be terminated. Swallowed rather than resolved
      # to `ESC` and the rest typed, which is the convention for a truncated CSI
      # and is wrong here: `11;rgb:1e1e` appearing in a text field is never what
      # anyone wanted, and losing a reply costs only the answer to a question
      # whose caller already has to cope with silence.
      return (nil, buf.len - i)
    of Esc:
      return (Msg(KeyMsg(key: kEsc)), 1)
    else:
      # ESC + key is how terminals report alt-modified keys.
      let (m, n) = parseOne(buf, i + 1, flushEsc, flushPaste)
      if n == 0: return incomplete()
      if m != nil and m of KeyMsg: KeyMsg(m).mods.incl mAlt
      return (m, n + 1)

  case b
  of '\r', '\n': return (Msg(KeyMsg(key: kEnter)), 1)
  of '\t': return (Msg(KeyMsg(key: kTab)), 1)
  of '\b', '\x7f': return (Msg(KeyMsg(key: kBackspace)), 1)
  of ' ': return (Msg(KeyMsg(key: kSpace, rune: Rune(' '))), 1)
  of '\0': return (Msg(KeyMsg(key: kSpace, mods: {mCtrl})), 1)
  of '\x01' .. '\x07', '\x0b', '\x0c', '\x0e' .. '\x1a':
    # Control characters map back onto their letter: 0x03 -> ctrl+c.
    return (Msg(KeyMsg(key: kRune, rune: Rune(b.ord + 96), mods: {mCtrl})), 1)
  of '\x1c' .. '\x1f':
    return (Msg(KeyMsg(key: kRune, rune: Rune(b.ord + 64), mods: {mCtrl})), 1)
  else:
    let n = utf8SeqLen(b)
    if n == 0: return (nil, 1)                  # invalid leading byte: skip
    if i + n > buf.len: return (nil, 0)         # rune split across reads
    var j = i
    var r: Rune
    fastRuneAt(buf, j, r, true)
    return (Msg(KeyMsg(key: kRune, rune: r)), j - i)

proc parseInput*(buf: string, flushEsc = false, flushPaste = false):
    tuple[msgs: seq[Msg], consumed: int] =
  ## Decode as many events as `buf` fully contains.
  ##
  ## Pass `flushEsc = true` when the read timed out, so that a trailing lone
  ## `ESC` is reported as the Escape key instead of being held indefinitely.
  ##
  ## Pass `flushPaste = true` when the read has timed out *repeatedly* — no byte
  ## at all for far longer than an escape sequence takes — so that a paste
  ## payload with no end marker behind it is delivered rather than held forever.
  ## The two are separate deliberately: `flushEsc` fires after a few tens of
  ## milliseconds, which is nothing at all in the middle of a real paste.
  var i = 0
  while i < buf.len:
    let (m, n) = parseOne(buf, i, flushEsc, flushPaste)
    if n == 0: break
    if m != nil: result.msgs.add m
    i += n
  result.consumed = i

proc holdsPaste*(buf: string): bool =
  ## True when what `parseInput` left unconsumed is a paste waiting for its end
  ## marker — so a caller can tell "an escape sequence is arriving" from "a paste
  ## is arriving", which want very different timeouts.
  ##
  ## Exact rather than a guess: `parseInput` consumes greedily from the front and
  ## the caller re-slices to what is left, so an unconsumed buffer begins at
  ## precisely whatever is being held.
  buf.continuesWith(PasteStart, 0)
