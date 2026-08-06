## Terminal device control: raw mode, size queries, non-blocking reads.
##
## Everything platform-specific is confined to this module. Ports to other
## platforms should only need to reimplement it.

when not defined(posix):
  {.error: "nimtui currently supports POSIX terminals only (see src/nimtui/tty.nim)".}

import std/[posix, termios, os, strutils]
import std/terminal as stdterm
import ./ansi

type
  Tty* = object
    input*, output*: File
    saved: Termios
    inRawMode: bool

  InputEvent* = enum
    ieTimeout      ## nothing arrived before the timeout elapsed
    ieReadable     ## bytes are waiting to be read
    ieClosed       ## the input stream hung up
    ieInterrupted
      ## a signal cut the wait short, so no time can be assumed to have passed
      ##
      ## Distinct from `ieTimeout` because the caller acts on a timeout: it
      ## resolves a held escape sequence on one, on the reasoning that the rest
      ## of the sequence is never coming. A SIGWINCH landing mid-sequence is not
      ## evidence of that, and reporting it as a timeout used to flush one.

  WinSize {.importc: "struct winsize", header: "<sys/ioctl.h>", final, pure.} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

var TIOCGWINSZ {.importc, header: "<sys/ioctl.h>".}: cuint
  ## SIGWINCH is not in POSIX, so std/posix does not declare it.
var SIGWINCH {.importc, header: "<signal.h>".}: cint

var resizePending {.volatile.}: bool

proc onResizeSignal(sig: cint) {.noconv.} =
  # Signal context: only touch a flag, the loop does the real work.
  resizePending = true

proc watchResize*() =
  ## Install the SIGWINCH handler. Idempotent.
  signal(SIGWINCH, onResizeSignal)
  resizePending = false

proc takeResizePending*(): bool =
  ## True if a resize arrived since the last call, clearing the flag.
  result = resizePending
  resizePending = false

# --- surviving a terminating signal ----------------------------------------
#
# The state a signal handler puts the terminal back from, declared here beside
# the resize flag because it is the same kind of thing: the only mutable globals
# in the library, and both exist because a signal handler has nowhere else to
# look. The bytes are assembled further down, next to the other escape writers.

const MaxRestoreBytes* = 128
  ## Headroom for the longest sequence `armRestore
  ## <#armRestore,Tty,bool,bool,bool,bool>`_ can be asked to hold. The worst case
  ## today is 66 bytes; `armRestore` asserts rather than truncating, so
  ## lengthening one of the escapes in `nimtui/ansi <ansi.html>`_ fails a test
  ## rather than silently emitting half of it.

type SigAtomic {.importc: "sig_atomic_t", header: "<signal.h>".} = cint

var
  armedFd: cint = -1                        ## the tty, or -1 when nothing is armed
  armedTermios: Termios                     ## the settings to put back
  armedBytes: array[MaxRestoreBytes, char]
    ## Precomputed, and a fixed array rather than a string: a Nim string is a
    ## heap pointer, and a signal arriving during the assignment would find a
    ## torn one. A handler cannot build a string either way.
  armedLen {.volatile.}: SigAtomic
    ## Written last, so a signal landing part way through arming reads a shorter
    ## sequence rather than garbage.
  restoreDone {.volatile.}: SigAtomic

proc emergencyRestore*() =
  ## Put the terminal back using nothing but `write(2)` and `tcsetattr`, both of
  ## which are async-signal-safe — which `write <#write,Tty,string>`_ is not,
  ## being Nim's stdio with a lock a signal can arrive holding. A no-op if
  ## nothing is armed.
  ##
  ## Public so an application that installs its own handler for one of these
  ## signals can still leave the terminal usable.
  if armedFd < 0: return
  # Not atomic, deliberately: the window is a few instructions and the only
  # consequence of losing the race is writing the same escapes twice.
  if restoreDone != 0: return
  restoreDone = 1
  var off = 0
  let total = armedLen.int
  while off < total:
    let n = write(armedFd, addr armedBytes[off], total - off)
    if n <= 0: break            # the tty may already be gone: SIGHUP's normal case
    off += n.int
  discard tcsetattr(armedFd, TCSAFLUSH, addr armedTermios)

proc disarmRestore*() =
  ## Forget the armed state. `exitRawMode <#exitRawMode,Tty>`_ does this, so a
  ## normal exit needs no extra call.
  armedFd = -1
  armedLen = 0

proc onTerminateSignal(sig: cint) {.noconv.} =
  # Unlike the resize handler this does the work rather than raising a flag. A
  # flag is only looked at inside the loop, and the terminal is already in raw
  # mode during the startup query, during `initCmd`, and during any command slow
  # enough to matter — all of which are exactly when a signal is worth surviving.
  emergencyRestore()
  # Re-raised with the default disposition so the exit status stays honest: a
  # process killed by SIGTERM must look killed by SIGTERM to whatever is
  # watching. This never returns.
  signal(sig, SIG_DFL)
  discard kill(getpid(), sig)

proc watchTerminate*() =
  ## Install handlers for the signals that end a process and would otherwise
  ## leave the terminal in raw mode, with no echo, the cursor hidden and mouse
  ## reporting on. Idempotent, and a sibling of `watchResize`_ in every respect.
  ##
  ## SIGINT is here because raw mode clears `ISIG`, so ctrl+c never generates
  ## one — an arriving SIGINT came from an explicit `kill` and means terminate.
  ##
  ## SIGKILL cannot be caught and should stay the only one that cannot. SIGSEGV,
  ## SIGABRT and SIGBUS deliberately are not caught: running this on a
  ## possibly-corrupt stack is the same class of bet on undocumented runtime
  ## behaviour that this codebase rejected for a threadpool, and Nim installs its
  ## own handlers there to print a traceback.
  for sig in [SIGTERM, SIGHUP, SIGINT, SIGQUIT]:
    signal(sig, onTerminateSignal)

proc initTty*(input = stdin, output = stdout): Tty =
  Tty(input: input, output: output)

proc isTerminal*(t: Tty): bool =
  stdterm.isatty(t.input) and stdterm.isatty(t.output)

proc enterRawMode*(t: var Tty) =
  ## Put the terminal into raw mode: no echo, no line buffering, no signal
  ## generation (so ctrl+c is delivered as a key), no output post-processing
  ## (so the renderer must emit `\r\n` itself).
  if t.inRawMode: return
  let fd = t.input.getFileHandle()
  if tcgetattr(fd, addr t.saved) != 0:
    raise newException(OSError, "tcgetattr failed: " & $strerror(errno))
  var raw = t.saved
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not OPOST
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_cc[VMIN] = char(0)      # reads return immediately
  raw.c_cc[VTIME] = char(0)
  if tcsetattr(fd, TCSAFLUSH, addr raw) != 0:
    raise newException(OSError, "tcsetattr failed: " & $strerror(errno))
  t.inRawMode = true

proc exitRawMode*(t: var Tty) =
  if not t.inRawMode: return
  discard tcsetattr(t.input.getFileHandle(), TCSAFLUSH, addr t.saved)
  t.inRawMode = false
  disarmRestore()

proc windowSize*(t: Tty): tuple[width, height: int] =
  ## Terminal size in cells, falling back to `$COLUMNS`/`$LINES` and then 80x24.
  ##
  ## Both axes have to be positive to be believed, and a non-positive value from
  ## either source is discarded rather than passed on. A zero would reach the
  ## renderer as `width` or `height` of 0, which is its encoding for "do not
  ## truncate" and "do not clip" — so instead of a degenerate frame the renderer
  ## would emit an unclipped one, which scrolls, breaking the no-wrap cursor
  ## arithmetic it depends on.
  var ws: WinSize
  if ioctl(t.output.getFileHandle(), TIOCGWINSZ.uint, addr ws) == 0 and
     ws.ws_col > 0.cushort and ws.ws_row > 0.cushort:
    return (ws.ws_col.int, ws.ws_row.int)
  result = (80, 24)
  try:
    let cols = getEnv("COLUMNS", "80").parseInt
    let rows = getEnv("LINES", "24").parseInt
    if cols > 0: result.width = cols
    if rows > 0: result.height = rows
  except ValueError:
    discard

proc waitForInput*(t: Tty, timeoutMs: int): InputEvent =
  ## Block until input is readable or `timeoutMs` elapses. A negative timeout
  ## waits indefinitely.
  var fds = TPollfd(fd: t.input.getFileHandle(), events: POLLIN, revents: 0)
  let n = poll(addr fds, 1.Tnfds, timeoutMs.cint)
  if n < 0: return (if errno == EINTR: ieInterrupted else: ieTimeout)
  if n == 0: return ieTimeout
  let ev = fds.revents.int
  if (ev and POLLIN.int) != 0: return ieReadable
  if (ev and (POLLHUP.int or POLLERR.int or POLLNVAL.int)) != 0: return ieClosed
  ieTimeout

proc readAvailable*(t: Tty, buf: var string): bool =
  ## Append every byte currently buffered on the input fd to `buf`.
  ##
  ## Returns false if the stream has ended. Call only after `waitForInput`
  ## reported `ieReadable`: raw mode sets VMIN=0, so a read of zero bytes is
  ## only meaningful as end-of-file when data was known to be waiting.
  result = true
  var chunk: array[1024, char]
  var total = 0
  while true:
    let n = read(t.input.getFileHandle(), addr chunk[0], chunk.len)
    if n == 0:
      return total > 0
    if n < 0:
      break                       # EAGAIN/EINTR: nothing more for now
    let start = buf.len
    buf.setLen start + n
    # One bulk copy, not `n` element assignments: a paste or a burst of mouse
    # motion arrives as several full chunks, so this is the one place in the input
    # path where a per-byte loop can grow into something measurable.
    copyMem(addr buf[start], addr chunk[0], n)
    total += n
    if n < chunk.len: break

proc write*(t: Tty, s: string) =
  if s.len == 0: return
  t.output.write s
  t.output.flushFile()

proc enterAltScreen*(t: Tty) = t.write EnterAltScreen & cursorTo(1, 1)
proc exitAltScreen*(t: Tty) = t.write ExitAltScreen
proc hideCursor*(t: Tty) = t.write HideCursor
proc showCursor*(t: Tty) = t.write ShowCursor

# --- putting the terminal back --------------------------------------------

proc restoreEscapesFor*(altScreen, hideCursor, mouse, bracketedPaste: bool): string =
  ## The escapes that undo the modes named, in the reverse of the order
  ## `setupTerminal` sets them.
  ##
  ## Split out from `restoreModes`_ for the same reason `renderer.frameFor` is
  ## split out from `render`: it is the only way to assert what gets written
  ## without a terminal to write it to. Keep the two in step.
  ##
  ## No trailing newline. On the normal path the renderer owns that, since only
  ## it knows whether a block is on screen at all.
  if bracketedPaste: result.add DisableBracketedPaste
  if mouse: result.add DisableMouse
  if hideCursor: result.add ShowCursor
  if altScreen: result.add ExitAltScreen

proc restoreModes*(t: Tty, altScreen, hideCursor, mouse, bracketedPaste: bool) =
  ## Write `restoreEscapesFor`_. The normal teardown path.
  t.write restoreEscapesFor(altScreen, hideCursor, mouse, bracketedPaste)

proc emergencyEscapesFor*(altScreen, hideCursor, mouse,
                          bracketedPaste: bool): string =
  ## What a terminating signal writes. `restoreEscapesFor`_ plus three things
  ## the normal path has no need of, because it never runs part way through a
  ## frame:
  ##
  ## * `EndSyncUpdate` first. The renderer wraps each frame in
  ##   `BeginSyncUpdate`/`EndSyncUpdate`, and a signal landing between them
  ##   leaves the terminal holding its display — which looks exactly like a hang.
  ## * `Reset`, because a signal can land between the escape that turns a colour
  ##   on and the one that turns it off. On the normal path `style.render` has
  ##   always emitted its closing reset by the time teardown runs.
  ## * A newline when not on the alt screen, unconditionally — where
  ##   `renderer.finish` emits one only if a block is on screen. A handler cannot
  ##   read that, and the two ways of being wrong are not symmetric: a spare
  ##   blank line before the shell prompt costs nothing, while omitting one when
  ##   a frame *is* on screen leaves the prompt overwriting its last line.
  result = EndSyncUpdate
  result.add restoreEscapesFor(altScreen, hideCursor, mouse, bracketedPaste)
  result.add Reset
  if not altScreen: result.add "\r\n"

proc armRestore*(t: Tty, altScreen, hideCursor, mouse, bracketedPaste: bool) =
  ## Arm `emergencyRestore`_ for the modes named. Call after `enterRawMode`,
  ## which is what saves the `Termios` this puts back.
  ##
  ## Takes modes rather than bytes because this module is meant to be the only
  ## one a port reimplements, so which escape a mode maps to stays decided here.
  ## Arming the full teardown before the modes are actually set is safe and is
  ## what keeps the unprotected window down to a few instructions: disabling a
  ## mouse that was never enabled, or leaving an alt screen never entered, are
  ## both no-ops.
  if not t.inRawMode: return
  let bytes = emergencyEscapesFor(altScreen, hideCursor, mouse, bracketedPaste)
  doAssert bytes.len <= MaxRestoreBytes,
    "restore sequence outgrew MaxRestoreBytes: " & $bytes.len
  for i, c in bytes: armedBytes[i] = c
  armedTermios = t.saved
  restoreDone = 0
  armedFd = t.input.getFileHandle()
  armedLen = bytes.len.SigAtomic     # last: see the declaration

proc enableMouse*(t: Tty, allMotion = false) =
  ## Turn on SGR mouse reporting: motion while a button is held, or all motion.
  ##
  ## Here rather than at the caller for the same reason as the toggles above —
  ## this module is meant to be the only one a port has to reimplement, so which
  ## escape sequence a mode maps to is decided in one place.
  t.write(if allMotion: EnableMouseAllMotion else: EnableMouseCellMotion)

proc disableMouse*(t: Tty) = t.write DisableMouse

proc enableBracketedPaste*(t: Tty) = t.write EnableBracketedPaste
proc disableBracketedPaste*(t: Tty) = t.write DisableBracketedPaste
