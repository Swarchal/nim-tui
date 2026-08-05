## Asking the terminal a question and reading its answer.
##
## Most of what a program needs to know about its terminal it can get without
## asking — the size comes from an `ioctl`, the capabilities from terminfo. The
## background *colour* cannot. There is no environment variable for it and no
## database entry, only OSC 11: send `ESC ] 11 ; ? ST` and a terminal that
## implements it replies on the input stream with its background as an X colour.
##
## What that buys is a style derived from the colour the user actually has rather
## than one chosen against the colour the developer had. A zebra stripe is the
## clearest case: mix the terminal's own background a few percent toward an
## accent and the stripe needs no foreground at all, because a shift that small
## cannot spoil whatever contrast the terminal's own foreground already had. A
## stripe picked in advance has to bring its own foreground, and on a terminal of
## the other polarity that is unreadable — the right number of columns, in the
## wrong colours, which no dimensional test can see.
##
## ```nim
## discard newProgram(model, update, view,
##                    options = {poAltScreen, poQueryBackground}).run()
## # update then receives one TerminalBgMsg before anything else.
## ```
##
## Use `nimtui/program <program.html>`_'s `poQueryBackground` unless there is a
## reason not to: the runtime already owns raw mode and the input stream at
## startup, which is the only moment the question can be asked without taking
## them away from something. `probeBackground` is here for a program that wants
## the answer *before* it builds its model, and pays for it by borrowing the
## terminal for a moment.
##
## Three properties this module is built around, all of them measured rather than
## assumed, and all of them worth re-measuring before being believed again:
##
## * **A reply that is not decoded is typed.** nimtui's input decoder consumes
##   OSC strings (see `nimtui/input <input.html>`_), so a late reply is dropped
##   rather than appearing in a text field. That was not always true, and it is
##   the reason asking is safe at all.
## * **tmux forwards this one.** Measured against tmux 3.4: the query reaches the
##   terminal beyond it and the answer comes back with *neither*
##   `allow-passthrough` nor `set-clipboard` set — the opposite of OSC 52, which
##   needs one of them. But the channels come back truncated to eight bits, so a
##   terminal answering `abcd/1234/5678` is relayed as `abab/1212/5656`. Hence
##   `scaleChannel`, which scales by the width of the field in front of it.
## * **Waiting for a reply that is not coming is the whole cost**, and it is
##   avoidable. See `DaQuery`.

import std/[monotimes, options, os, strutils, times]
import ./[ansi, color, tty]

# `Color` and `Option` both appear in the signatures below, so a caller who
# imports this module alone can still name what it hands back.
export color
export options

const
  DefaultQueryDeadlineMs* = 250
    ## How long to wait for an answer. Only ever reached by a terminal that
    ## answers nothing at all — with the sentinel below, a terminal that declines
    ## ends the wait as soon as it declines. Sized for one ssh round trip rather
    ## than for the sub-millisecond local case, because a query forwarded by tmux
    ## has a network to cross and is exactly where the sentinel cannot be
    ## trusted.

  DaQuery = Csi & "c"
    ## A primary device-attributes request, sent immediately behind the real
    ## question as a sentinel.
    ##
    ## Every terminal answers DA1, and answers come back in the order the
    ## questions went out — so a DA1 reply arriving with no colour in front of it
    ## *proves* the terminal declined, where a timeout only guesses. Measured
    ## against a pty that ignores OSC 11: the probe returns in under a
    ## millisecond instead of at the deadline. Startup cost is the reason to care;
    ## a quarter of a second before the first frame is visible.
    ##
    ## Not trusted under tmux, which is what `$TMUX` is read for. Measured
    ## against tmux 3.4: it answers DA1 out of its own head and at once
    ## (`ESC[?1;2;4c`) while *forwarding* the colour query onward. Locally both
    ## come back within a millisecond and the order still holds; over ssh the
    ## local answer overtakes the forwarded one and the sentinel means nothing.
    ## There the deadline is all there is.

type
  OscReply* = object
    ## Where an OSC reply sits in a buffer, and what it said.
    ##
    ## The position is part of the answer because the buffer is shared: a reply
    ## arrives among the sentinel's answer and among anything the user typed in
    ## the meantime, and a caller that wants to hand those keystrokes on has to
    ## know which bytes were not theirs.
    found*: bool
    body*: string    ## after `<code>;`, before the terminator
    at*, len*: int   ## the whole sequence's extent, `ESC` and terminator included

proc findOscReply*(s: string, code: int): OscReply =
  ## The OSC reply with this code anywhere in `s`, if one is complete.
  ##
  ## Scans rather than matching from the start: the position of a reply on a
  ## shared input stream is not knowable. An unterminated one is reported as not
  ## found, so a caller reading incrementally simply asks again with more bytes.
  let
    tag = "]" & $code & ";"
    hit = s.find(tag)
  if hit < 0: return OscReply()

  # The `ESC` is matched by stepping back rather than being part of `tag`, so a
  # reply whose first byte was lost is still read — and so that `at` covers the
  # escape when it is there, which is what makes the extent safe to excise.
  var start = hit
  if start > 0 and s[start - 1] == Esc: dec start

  let bodyStart = hit + tag.len
  var
    stop = -1        # first byte of the terminator
    after = -1       # first byte past it
    j = bodyStart
  while j < s.len:
    if s[j] == '\a':
      (stop, after) = (j, j + 1)
      break
    if s[j] == Esc and j + 1 < s.len and s[j + 1] == '\\':
      (stop, after) = (j, j + 2)
      break
    inc j
  if stop < 0: return OscReply()

  OscReply(found: true, body: s[bodyStart ..< stop], at: start, len: after - start)

proc scaleChannel(field: string): int =
  ## A hex channel of any width scaled to 0..255.
  ##
  ## The width is neither fixed nor guessable: xterm's own definition allows one
  ## to four digits, and tmux relays eight bits of whatever it was told. Scaling
  ## by the width present reads `abab` and `ab` as the same colour, where taking
  ## the first two digits would read `rgb:1e/1e/1e` as `rgb:1e00…` — nothing at
  ## all.
  let
    v = parseHexInt(field)
    full = (1 shl (4 * field.len)) - 1
  (v * 255 + full div 2) div full

proc parseColorReply*(body: string): Option[Color] =
  ## The colour out of an OSC 10/11 reply body: `rgb:RRRR/GGGG/BBBB`, channels of
  ## any width, or the `#rrggbb` spelling.
  ##
  ## Both forms are accepted because both are sent, and an unparsed answer is
  ## indistinguishable from no answer at all — which lands the caller on exactly
  ## the fallback that asking was meant to avoid.
  if body.startsWith("rgb:"):
    let channels = body[4 .. ^1].split('/')
    if channels.len != 3: return none(Color)
    for c in channels:
      if c.len == 0 or c.len > 4 or not c.allCharsInSet(HexDigits):
        return none(Color)
    return some(rgb(channels[0].scaleChannel, channels[1].scaleChannel,
                    channels[2].scaleChannel))

  if body.len == 7 and body[0] == '#' and body[1 .. ^1].allCharsInSet(HexDigits):
    return some(rgb(parseHexInt(body[1 .. 2]), parseHexInt(body[3 .. 4]),
                    parseHexInt(body[5 .. 6])))

  none(Color)

proc hasDaReply*(s: string): bool =
  ## True once a primary device-attributes reply — `ESC [ ? … c` — is in `s`.
  let at = s.find(Csi & "?")
  at >= 0 and s.find('c', at) >= 0

proc queryColor*(t: var Tty, code: int, leftover: var string,
                 deadlineMs = DefaultQueryDeadlineMs): Color =
  ## Ask the terminal an OSC colour question and wait for the answer.
  ##
  ## `code` is the OSC code — 10 for the foreground, 11 for the background.
  ## Returns `ckDefault` for every way of not finding out: not a terminal, a
  ## terminal that declines, a malformed answer, a write that failed. The caller
  ## cannot act differently on any of them, so they are not distinguished.
  ##
  ## `t` must already be in raw mode: the reply is bytes on the input stream, and
  ## a line-buffered terminal will not hand them over until Enter is pressed.
  ##
  ## Every byte read that was not part of the reply is **appended to
  ## `leftover`**, in order. Those are somebody's keystrokes — the window between
  ## the question and the answer is short but not empty — and a caller running an
  ## input loop afterwards should feed them to it rather than drop them. A DA1
  ## reply may be among them; that is safe to pass on, because the input decoder
  ## consumes an unrecognised CSI without producing a message.
  ##
  ## Never raises and never blocks longer than `deadlineMs`.
  if not t.isTerminal: return Color()
  let sentinelTrusted = getEnv("TMUX").len == 0

  try:
    # One write, and the sentinel goes out behind the question in the same one:
    # the ordering the sentinel relies on is the ordering of the bytes, not of
    # two calls that something could interleave.
    t.write("\e]" & $code & ";?\e\\" & DaQuery)
  except CatchableError:
    return Color()

  var buf = ""
  let started = getMonoTime()
  while true:
    let left = deadlineMs - (getMonoTime() - started).inMilliseconds.int
    if left <= 0: break
    if t.waitForInput(left) != ieReadable: break
    if not t.readAvailable(buf): break

    let reply = findOscReply(buf, code)
    if reply.found:
      # The reply's own bytes come out of the buffer and the rest is the
      # caller's; the answer is only ckDefault here if it did not parse.
      leftover.add buf[0 ..< reply.at]
      leftover.add buf[reply.at + reply.len .. ^1]
      let c = parseColorReply(reply.body)
      return if c.isSome: c.get else: Color()

    # The sentinel has answered and the colour has not, which off tmux settles
    # it. Under tmux, keep waiting for the deadline — see `DaQuery`.
    if sentinelTrusted and buf.hasDaReply: break

  leftover.add buf
  Color()

proc queryBackground*(t: var Tty, leftover: var string,
                      deadlineMs = DefaultQueryDeadlineMs): Color =
  ## The terminal's background colour, or `ckDefault` if it will not say.
  queryColor(t, 11, leftover, deadlineMs)

proc queryForeground*(t: var Tty, leftover: var string,
                      deadlineMs = DefaultQueryDeadlineMs): Color =
  ## The terminal's foreground colour, or `ckDefault` if it will not say.
  queryColor(t, 10, leftover, deadlineMs)

proc probeBackground*(deadlineMs = DefaultQueryDeadlineMs): Color =
  ## Ask on `stdin`/`stdout`, taking raw mode for the duration.
  ##
  ## For a program that wants the answer before it has a model to put it in.
  ## Prefer `poQueryBackground`, which asks inside the runtime and hands the
  ## answer to `update` as a `TerminalBgMsg`: it borrows nothing, and it cannot
  ## drop a keystroke.
  ##
  ## Anything typed while this runs *is* dropped, and deliberately: `exitRawMode`
  ## restores with `TCSAFLUSH`, which discards what is queued. Leaving those
  ## bytes for whatever the program does next would mean handing a cooked-mode
  ## terminal a fragment of a reply.
  var t = initTty()
  if not t.isTerminal: return Color()
  try:
    t.enterRawMode()
  except OSError:
    return Color()
  defer: t.exitRawMode()
  var discarded = ""
  queryBackground(t, discarded, deadlineMs)
