## Compile every top-level `examples/*.nim` into `bin/`, several at once.
##
## Run by `nimble examples`. It is a compiled helper rather than a loop in the
## .nimble file because NimScript has no `osproc` and its `exec` blocks until the
## command returns — so an in-file loop is necessarily sequential. `execProcesses`
## gives a worker pool sized to the machine for free.
##
## The win is real but bounded (~1.7x on an 8-core box, cold): each `nim c`
## already runs its C-compilation stage across every core, so what parallelising
## the *Nim* invocations buys is overlapping one build's single-threaded semcheck
## with another's C stage. Past `countProcessors() div 2` or so it stops helping.
##
## `examples/treesitter/` is deliberately not reached — `walkFiles` with a glob
## is not recursive, the same reason `nimble snippets` is a separate task.

import std/[os, osproc, sequtils, strutils]

when isMainModule:
  createDir "bin"
  let files = toSeq(walkFiles("examples/*.nim"))
  if files.len == 0:
    quit "no examples found — run this from the package root"

  let names = files.mapIt(it.extractFilename.changeFileExt(""))
  let cmds = files.mapIt(
    "nim c --path:src -d:release --hints:off -o:bin/" &
    it.extractFilename.changeFileExt("") & " " & it)

  # `poParentStreams` (the default): a successful `--hints:off` build is silent,
  # and a failure's errors go straight to the terminal. Draining the pipes
  # ourselves instead would deadlock any build that printed more than a pipe
  # buffer before we got to read it.
  var failed: seq[string]
  proc announce(i: int) =
    echo "building ", names[i]
  proc record(i: int, p: Process) =
    if p.peekExitCode != 0: failed.add names[i]

  let code = execProcesses(cmds, n = max(countProcessors(), 1),
                           beforeRunEvent = announce, afterRunEvent = record)

  if failed.len > 0:
    quit "failed: " & failed.join(", ")
  echo "built ", names.len, " examples into bin/"
  quit code
