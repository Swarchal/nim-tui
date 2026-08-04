## Why nimtui has no concurrent commands. Run this by hand:
##
##   nim c -r --hints:off -d:release tests/manual/orc_closure_threads.nim
##
## Deliberately excluded from `nimble test` (which only picks up `tests/t*.nim`)
## because case 2 is expected to crash the process.
##
## The finding: under `--mm:orc`, Nim 2.x's default, an object carrying a
## **closure** cannot round-trip main thread -> worker -> main thread. A closure
## is a `(proc, env)` pair whose environment field is internally a `RootRef`, so
## ORC cannot prove it acyclic and tracks it through a thread-local cycle-root
## buffer. Touching that buffer from two threads corrupts it, and the corruption
## surfaces as a SIGSEGV inside the collector — `nimDecRefIsLastCyclicDyn` ->
## `rememberCycle` -> `unregisterCycle` — nowhere near the offending code.
##
## The same applies to `Msg` and to `ref Exception`: both inherit `RootObj`.
##
## Measured on Nim 2.2.4 / Linux x86-64:
##
## | carrier holds                     | orc     | arc   |
## | --------------------------------- | ------- | ----- |
## | `{.nimcall.}` proc + plain data   | clean   | clean |
## | `{.closure.}` proc                | SIGSEGV | clean |
##
## Both cases below are otherwise identical: same pool, same queues, same
## payload, same round-trip. Only the calling convention differs.
##
## Re-run this on a newer Nim before reconsidering a threadpool. If case 2 stops
## crashing, the constraint has been lifted upstream.

import std/[locks, os, strutils]

type Job[T] = ref object
  fn: T
  arg, res: string

var lk: Lock
var live = true
initLock lk

# --- case 1: {.nimcall.} — a bare function pointer, no environment ------------

type NimcallFn = proc (arg: string): string {.nimcall, gcsafe.}
var q1 {.guard: lk.}: seq[Job[NimcallFn]]
var done1 {.guard: lk.}: seq[Job[NimcallFn]]

proc nimcallWorker(id: int) {.thread.} =
  while true:
    var j: Job[NimcallFn]
    withLock lk:
      {.cast(gcsafe).}:
        if not live and q1.len == 0: return
        if q1.len > 0:
          j = q1[0]
          q1.delete 0
    if j == nil:
      sleep 1
      continue
    {.cast(gcsafe).}:
      j.res = j.fn(j.arg)
      withLock lk: done1.add j

proc work(arg: string): string {.nimcall, gcsafe.} = "ok:" & arg

# --- case 2: {.closure.} — identical, but the env is a RootRef ----------------

type ClosureFn = proc (arg: string): string {.closure, gcsafe.}
var q2 {.guard: lk.}: seq[Job[ClosureFn]]
var done2 {.guard: lk.}: seq[Job[ClosureFn]]

proc closureWorker(id: int) {.thread.} =
  while true:
    var j: Job[ClosureFn]
    withLock lk:
      {.cast(gcsafe).}:
        if not live and q2.len == 0: return
        if q2.len > 0:
          j = q2[0]
          q2.delete 0
    if j == nil:
      sleep 1
      continue
    {.cast(gcsafe).}:
      j.res = j.fn(j.arg)
      withLock lk: done2.add j

const N = 20000

proc runNimcall() =
  var ts: array[6, Thread[int]]
  live = true
  for i in 0 ..< 6: createThread(ts[i], nimcallWorker, i)
  for i in 0 ..< N:
    let j = Job[NimcallFn](fn: work, arg: "item-" & $i)
    withLock lk: {.cast(gcsafe).}: q1.add j
  var seen = 0
  while seen < N:
    var b: seq[Job[NimcallFn]]
    withLock lk: {.cast(gcsafe).}: b = move done1
    for j in b:
      doAssert j.res.startsWith("ok:")
      inc seen
    if b.len == 0: sleep 1
  withLock lk: {.cast(gcsafe).}: live = false
  joinThreads(ts)
  echo "case 1 ({.nimcall.}):  ", seen, " jobs, no crash"

proc runClosure() =
  var ts: array[6, Thread[int]]
  live = true
  for i in 0 ..< 6: createThread(ts[i], closureWorker, i)
  for i in 0 ..< N:
    let j = Job[ClosureFn](fn: work, arg: "item-" & $i)
    withLock lk: {.cast(gcsafe).}: q2.add j
  var seen = 0
  while seen < N:
    var b: seq[Job[ClosureFn]]
    withLock lk: {.cast(gcsafe).}: b = move done2
    for j in b:
      doAssert j.res.startsWith("ok:")
      inc seen
    if b.len == 0: sleep 1
  withLock lk: {.cast(gcsafe).}: live = false
  joinThreads(ts)
  echo "case 2 ({.closure.}):  ", seen, " jobs, no crash"

runNimcall()
echo "case 2 follows; under --mm:orc it is expected to SIGSEGV in the collector"
runClosure()
echo "both cases survived — check whether the ORC constraint still holds"
