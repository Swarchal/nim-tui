## Terminal queries, without a terminal.
##
## `queryColor` is never driven against a real tty here. A suite that asked the
## terminal a question would either read bytes out from under whoever is running
## it or wait out the deadline on every run — and `nimble test` paying a quarter
## of a second per invocation is exactly the cost the DA1 sentinel exists to
## avoid, so it must not be spent here of all places.
##
## What is left is everything that can be decided from a string: which bytes are
## a reply, where they sat, and what colour they name. The one test that does call
## the probe checks the case with no terminal to ask, which is free and is what
## the suite itself runs under.
##
## The wire — raw mode, the poll, whether the sentinel really ends the wait early
## — is `tests/manual/background.py`. Half of that driver's assertions are about
## how long the probe took, which is the half that fails silently: a probe
## returning the right answer by waiting out the deadline every time looks correct
## in every assertion here.

import std/[times, unittest]
import nimtui/[color, query]

suite "finding a reply in a buffer":
  test "the ordinary form":
    let r = findOscReply("\e]11;rgb:1e1e/1e1e/1e1e\e\\", 11)
    check r.found
    check r.body == "rgb:1e1e/1e1e/1e1e"

  test "BEL terminates as well as ST":
    check findOscReply("\e]11;rgb:00/00/00\a", 11).body == "rgb:00/00/00"

  test "the terminator is not left on the body":
    # Cutting at the terminator is not optional: `ESC \` on the end of the last
    # channel makes the whole reply unparseable, which is indistinguishable from
    # no reply at all and lands on the fallback the query exists to avoid.
    for term in ["\e\\", "\a"]:
      let r = findOscReply("\e]11;rgb:ab/cd/ef" & term, 11)
      check r.body == "rgb:ab/cd/ef"

  test "a reply among other bytes, and its extent":
    # The extent is what lets the caller keep the keystrokes and drop the reply.
    let s = "q\e]11;#ffffff\e\\z"
    let r = findOscReply(s, 11)
    check r.found
    check r.body == "#ffffff"
    check s[r.at ..< r.at + r.len] == "\e]11;#ffffff\e\\"
    check s[0 ..< r.at] & s[r.at + r.len .. ^1] == "qz"

  test "the code has to match":
    # 10 is the foreground. Answering a background query with it would derive
    # every colour in the theme from the wrong end of the contrast range.
    check not findOscReply("\e]10;rgb:ff/ff/ff\e\\", 11).found
    check findOscReply("\e]10;rgb:ff/ff/ff\e\\", 10).found

  test "an unterminated reply is not found yet":
    # Reported as absent rather than as a short body, so a caller reading
    # incrementally simply asks again once more bytes have arrived.
    check not findOscReply("\e]11;rgb:1e1e/1e", 11).found

  test "a reply whose escape was lost is still read":
    let r = findOscReply("]11;rgb:00/11/22\a", 11)
    check r.found
    check r.at == 0

suite "the colour out of a reply":
  test "16 bits per channel":
    check parseColorReply("rgb:2e34/3436/4144").get == rgb(46, 52, 65)

  test "8 bits per channel is the same colour":
    # Which is what tmux relays: measured against 3.4, a terminal answering
    # `abcd/1234/5678` comes back as `abab/1212/5656`, and both of those have to
    # mean what the terminal meant. Slicing the first two digits instead would
    # read `rgb:1e/1e/1e` as `rgb:1e00…`, i.e. nothing.
    check parseColorReply("rgb:abab/1212/5656").get ==
          parseColorReply("rgb:ab/12/56").get
    check parseColorReply("rgb:ab/12/56").get == rgb(171, 18, 86)

  test "any width from one to four digits":
    for field in ["f", "ff", "fff", "ffff"]:
      checkpoint field
      check parseColorReply("rgb:" & field & "/" & field & "/" & field).get ==
            rgb(255, 255, 255)
    for field in ["0", "00", "000", "0000"]:
      check parseColorReply("rgb:" & field & "/" & field & "/" & field).get ==
            rgb(0, 0, 0)

  test "the hash spelling":
    check parseColorReply("#1e1e1e").get == rgb(30, 30, 30)

  test "what is refused":
    for bad in ["", "rgb:", "rgb:1e/1e", "rgb:1e/1e/1e/1e", "rgb:zz/00/00",
                "rgb:12345/00/00", "rgb://", "#12345", "#gggggg", "rgba:1/2/3",
                "1e1e1e"]:
      checkpoint bad
      check parseColorReply(bad).isNone

suite "the sentinel":
  test "a DA1 reply is recognised":
    check hasDaReply("\e[?1;2;4c")
    check hasDaReply("\e[?62;c")

  test "and an incomplete one is not":
    # Half a sentinel must not end the wait: the whole point is that DA1 arriving
    # *after* the colour would have proves the colour is not coming, and a partial
    # one proves nothing at all.
    check not hasDaReply("\e[?1;2;4")
    check not hasDaReply("")
    check not hasDaReply("\e]11;rgb:1e1e/1e1e/1e1e\e\\")

suite "the probe with nothing to ask":
  test "a stdin that is not a terminal answers at once and costs nothing":
    # Both halves matter. `ckDefault` is the answer a caller must already handle,
    # and *immediately* is what keeps `nimble test` — which runs with stdin
    # redirected, as does any CI — from paying the deadline for every suite that
    # links this module.
    let started = cpuTime()
    let bg = probeBackground()
    check bg.kind == ckDefault
    check cpuTime() - started < 0.05
