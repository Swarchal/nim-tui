## A one-shot `probeBackground`, for `background.py` to drive under a pty.
##
##     nim c --path:src tests/manual/askbg.nim
##
## Writes its answer to the file named by the first argument rather than to
## stdout, because stdout *is* the pty the driver is playing terminal on and a
## line of text there would be read as part of the conversation.
##
## Reports how long the probe took as well as what it decided. That is the half
## of the behaviour nothing else can see: a probe that returns the right answer
## by waiting out the deadline every time is correct in every assertion in
## `tests/tquery.nim` and adds a quarter of a second to every startup.
##
## Deliberately not named `t*`, so `nimble test` does not compile it — it is a
## fixture with no assertions in it, and the assertions are in the driver.

import std/[monotimes, os, times]
import nimtui/[color, query]

let started = getMonoTime()
let bg = probeBackground()
let took = (getMonoTime() - started).inMilliseconds

writeFile(paramStr(1),
  (if bg.kind == ckDefault: "declined"
   else: "rgb(" & $bg.toRgb.r & "," & $bg.toRgb.g & "," & $bg.toRgb.b & ")") &
  " " & $took & "\n")
