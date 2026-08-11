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

  TerminalMode* = enum
    ## A terminal mode this module can turn on, and therefore has to turn off
    ## again. `program`'s `ProgramOption` maps onto this; the two are separate
    ## because the options include things that are not modes at all, and because
    ## this module is meant to be the only one a port reimplements.
    ##
    ## A set rather than one bool per mode in every signature: five positional
    ## bools that all mean "was this on" is a transposition waiting to happen,
    ## and transposing two of them writes a plausible-looking wrong sequence.
    tmAltScreen
    tmLineWrap
      ## Auto-wrap turned *off* — the mode is named for what was changed, like
      ## the others, not for the state it was put into. Unlike the others it is
      ## not something an application asks for: the renderer's arithmetic assumes
      ## no wrapping, so keeping the terminal from wrapping is the library's own
      ## business and `program` sets it unconditionally.
    tmHideCursor
    tmMouse
    tmBracketedPaste
    tmFocus

  MouseTracking* = enum
    ## How much the terminal is asked to report. Each level adds to the one
    ## before it, and `tmMouse` undoes all three alike.
    ##
    ## An enum rather than the `allMotion: bool` this took before, because there
    ## are three answers and a bool holds two — the missing one being the level
    ## most applications actually want. A bool also reads badly at the call site:
    ## `enableMouse(t, true)` says nothing about which of them it means.
    mtClicks       ## button press and release only
    mtCellMotion   ## also motion, while a button is held
    mtAllMotion    ## also motion with no button held

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
  ## today is 74 bytes; `armRestore` asserts rather than truncating, so
  ## lengthening one of the escapes in `nimtui/ansi <ansi.html>`_ fails a test
  ## rather than silently emitting half of it.

type SigAtomic {.importc: "sig_atomic_t", header: "<signal.h>".} = cint

var
  armedOutFd: cint = -1
    ## Where the teardown escapes go, or -1 when nothing is armed. The *output*
    ## side, like every other escape writer here — `input` and `output` are two
    ## parameters of `run` and need not be the same device, and a restore written
    ## to the one being read from leaves the alt screen, the cursor and the mouse
    ## exactly as the signal found them on the one being drawn to.
  armedInFd: cint = -1
    ## Where the `Termios` goes back, which is the *input* side: that is the fd
    ## `enterRawMode` called `tcsetattr` on, and putting the settings back on the
    ## other one restores nothing and modifies a terminal that was never touched.
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
  if armedOutFd < 0: return
  # Not atomic, deliberately: the window is a few instructions and the only
  # consequence of losing the race is writing the same escapes twice.
  if restoreDone != 0: return
  restoreDone = 1
  var off = 0
  let total = armedLen.int
  while off < total:
    let n = write(armedOutFd, addr armedBytes[off], total - off)
    if n <= 0: break            # the tty may already be gone: SIGHUP's normal case
    off += n.int
  discard tcsetattr(armedInFd, TCSAFLUSH, addr armedTermios)

proc restoreHappened*(): bool =
  ## Has `emergencyRestore`_ run since the last `armRestore <#armRestore,Tty,set[TerminalMode]>`_?
  ##
  ## The question a resume has to ask, and it has two different answers. Stopped
  ## by SIGTSTP, the handler put the terminal back and taking it again means
  ## entering raw mode afresh. Stopped by SIGSTOP — which cannot be caught, so no
  ## handler ran — the terminal is still exactly as the program left it, and
  ## "entering raw mode afresh" would save the *raw* settings as the ones to
  ## restore on exit. That leaves the shell in raw mode at the end of a run that
  ## did everything else right.
  restoreDone != 0

proc disarmRestore*() =
  ## Forget the armed state. `exitRawMode <#exitRawMode,Tty>`_ does this, so a
  ## normal exit needs no extra call.
  armedOutFd = -1
  armedInFd = -1
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

# --- being stopped and started again ----------------------------------------
#
# The other signal the library's own raw mode makes unreachable. `enterRawMode`
# clears `ISIG`, so ctrl+z never generates a SIGTSTP; one that arrives came from
# an explicit `kill`, and its default action stops the process with the terminal
# in raw mode, the alt screen up, the cursor hidden and a mouse reporting. The
# shell that gets the terminal back then needs `reset`, which is the exact
# failure `watchTerminate` exists to prevent — so this is repair of damage the
# library does, on the same argument, and not a feature.
#
# It is split across the two handlers because a stop and a resume are not the
# same kind of event. Stopping happens immediately and cannot wait for the loop,
# so it restores from the handler like a terminating signal does; resuming has
# to set a terminal *up*, which is a great deal more than `write(2)` and
# `tcsetattr`, so it raises a flag like a resize does.

var resumePending {.volatile.}: bool

proc onSuspendSignal(sig: cint) {.noconv.}

proc onContinueSignal(sig: cint) {.noconv.} =
  # A bare SIGCONT, with no stop of ours in front of it, is not hypothetical:
  # SIGSTOP cannot be caught, so a process stopped that way is resumed through
  # here and through nothing else. The terminal was never restored in that
  # case — see `restoreHappened`_, which is how the resume tells the two apart.
  resumePending = true

proc onSuspendSignal(sig: cint) {.noconv.} =
  # `onTerminateSignal`'s shape, and the same reasoning about why a flag would be
  # too late: the terminal is in raw mode during the startup query, during
  # `initCmd` and during any slow command. The difference is that this one comes
  # back, so the latch inside `emergencyRestore` has to be cleared before the
  # next stop — `armRestore` does that, and `setupTerminal` calls it on resume.
  emergencyRestore()

  # Unblocked across the re-raise, and this is the whole of why a stop handler is
  # harder than a terminate one. A handler runs with its own signal blocked, so
  # the re-raise below would merely become *pending* and would not be delivered
  # until this returns — by which point the disposition has been put back and the
  # process re-enters this handler instead of stopping. That is not a delayed
  # stop but an unbounded loop, and it looks from outside exactly like a program
  # that ignores ctrl+z. Unblocking makes the raise stop the process here, on
  # this line, which is what everything below assumes.
  #
  # `sigemptyset`, `sigaddset`, `sigprocmask` and `kill` are all on POSIX's
  # async-signal-safe list, as `write` and `tcsetattr` are.
  var mask, prev: Sigset
  discard sigemptyset(mask)
  discard sigaddset(mask, SIGTSTP)
  signal(SIGTSTP, SIG_DFL)
  discard sigprocmask(SIG_UNBLOCK, mask, prev)
  discard kill(getpid(), SIGTSTP)
  discard sigprocmask(SIG_BLOCK, mask, prev)

  # Reached two ways, and the second one is why the flag is set here rather than
  # only in `onContinueSignal`. Either the process stopped and was continued, or
  # **the stop never happened**: the kernel discards a stop signal sent to an
  # orphaned process group, precisely so nothing can be left stopped with no
  # parent able to continue it. A program run from a job-control shell is never
  # in one; a program whose shell has since exited, or one under a bare
  # `pty.fork` with no intervening process group, is. Without this the terminal
  # has been handed back, the program is still running, and no SIGCONT is ever
  # coming to say so.
  #
  # Also where the handler is put back, for the same reason it had to be taken
  # down at all — and safely, now that the raise above has already happened
  # rather than being left pending.
  signal(SIGTSTP, onSuspendSignal)
  resumePending = true

proc watchSuspend*() =
  ## Install the SIGTSTP and SIGCONT handlers. Idempotent, and a sibling of
  ## `watchTerminate`_ in every respect.
  signal(SIGTSTP, onSuspendSignal)
  signal(SIGCONT, onContinueSignal)
  resumePending = false

proc rawModeLost*(t: var Tty) =
  ## Record that something outside this object put the terminal back.
  ##
  ## There is exactly one such thing: `onSuspendSignal` above, which calls
  ## `tcsetattr` directly because a handler cannot reach a `Tty`. Without this,
  ## `enterRawMode`'s idempotence guard sees `inRawMode` still set and taking the
  ## terminal again on resume is a *silent no-op* — the program carries on
  ## drawing frames to a cooked terminal, which echoes every keystroke back over
  ## them and needs no signal, no error and no failed syscall to happen.
  ## `armRestore` is guarded on the same flag, so the next stop would also find
  ## nothing armed.
  t.inRawMode = false

proc suspendProcess*() =
  ## Stop this process, returning when it is continued.
  ##
  ## Here rather than at the caller for the reason every other syscall in this
  ## module is: `program` names no platform primitive, so a port replaces this
  ## file and nothing else. It deliberately does not restore the terminal —
  ## `onSuspendSignal` above is reached by this `kill` and does that, so the
  ## explicit route and an externally delivered stop are one path instead of two
  ## that could come to disagree.
  discard kill(getpid(), SIGTSTP)

proc takeResumePending*(): bool =
  ## True if the process was continued since the last call, clearing the flag.
  ## The caller owes the terminal a full setup and a repaint: a shell has been
  ## drawing on it, so nothing the renderer believes about the screen is true.
  result = resumePending
  resumePending = false

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

proc pixelSize*(t: Tty): tuple[width, height: int] =
  ## Terminal size in pixels, or `(0, 0)` if the terminal did not say.
  ##
  ## What an image protocol needs, and the one number that cannot be derived from
  ## anything else the library reports: cells divided into pixels is the cell
  ## size, which is what decides how many rows an image occupies.
  ##
  ## Zero is *unknown*, in the `ckDefault` sense rather than the renderer's — a
  ## great many terminals leave these fields at zero, and there is no fallback
  ## to reach for, no environment variable and no sensible default. A caller that
  ## cannot cope without an answer should not be asking. Separate from
  ## `windowSize`_ for that reason: the cell size always has an answer and this
  ## usually does not, so folding them together would put a number nobody can
  ## trust beside two everybody can.
  var ws: WinSize
  if ioctl(t.output.getFileHandle(), TIOCGWINSZ.uint, addr ws) == 0:
    return (ws.ws_xpixel.int, ws.ws_ypixel.int)

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

proc restoreEscapesFor*(modes: set[TerminalMode]): string =
  ## The escapes that undo `modes`, in the reverse of the order
  ## `setupTerminal` sets them.
  ##
  ## Split out from `restoreModes`_ for the same reason `renderer.frameFor` is
  ## split out from `render`: it is the only way to assert what gets written
  ## without a terminal to write it to. Keep the two in step.
  ##
  ## No trailing newline. On the normal path the renderer owns that, since only
  ## it knows whether a block is on screen at all.
  if tmFocus in modes: result.add DisableFocusReporting
  if tmBracketedPaste in modes: result.add DisableBracketedPaste
  if tmMouse in modes: result.add DisableMouse
  if tmHideCursor in modes: result.add ShowCursor
  # Before leaving the alt screen, since that is the order `setupTerminal` set
  # them in reversed: auto-wrap is turned off once the program owns the screen,
  # so it goes back on while the program still does.
  if tmLineWrap in modes: result.add EnableLineWrap
  if tmAltScreen in modes: result.add ExitAltScreen

proc restoreModes*(t: Tty, modes: set[TerminalMode]) =
  ## Write `restoreEscapesFor`_. The normal teardown path.
  t.write restoreEscapesFor(modes)

proc emergencyEscapesFor*(modes: set[TerminalMode]): string =
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
  result.add restoreEscapesFor(modes)
  result.add Reset
  if tmAltScreen notin modes: result.add "\r\n"

proc armRestore*(t: Tty, modes: set[TerminalMode]) =
  ## Arm `emergencyRestore`_ for `modes`. Call after `enterRawMode`,
  ## which is what saves the `Termios` this puts back.
  ##
  ## Takes modes rather than bytes because this module is meant to be the only
  ## one a port reimplements, so which escape a mode maps to stays decided here.
  ## Arming the full teardown before the modes are actually set is safe and is
  ## what keeps the unprotected window down to a few instructions: disabling a
  ## mouse that was never enabled, or leaving an alt screen never entered, are
  ## both no-ops.
  if not t.inRawMode: return
  let bytes = emergencyEscapesFor(modes)
  doAssert bytes.len <= MaxRestoreBytes,
    "restore sequence outgrew MaxRestoreBytes: " & $bytes.len
  for i, c in bytes: armedBytes[i] = c
  armedTermios = t.saved
  restoreDone = 0
  armedInFd = t.input.getFileHandle()
  armedOutFd = t.output.getFileHandle()
  armedLen = bytes.len.SigAtomic     # last: see the declaration

proc enableMouse*(t: Tty, tracking: MouseTracking) =
  ## Turn on SGR mouse reporting at `tracking`.
  ##
  ## Here rather than at the caller for the same reason as the toggles above —
  ## this module is meant to be the only one a port has to reimplement, so which
  ## escape sequence a mode maps to is decided in one place.
  ##
  ## No default. There is one obvious candidate — the level this used to imply —
  ## but which of three a bare `enableMouse(t)` means is exactly the question the
  ## enum exists to stop anyone having to ask.
  ##
  ## Adding a level needs nothing in `restoreEscapesFor`_, since `DisableMouse`
  ## turns off all three. `tmMouse` is the only mode where that holds; every
  ## other one is a mode and its inverse.
  t.write:
    case tracking
    of mtClicks: EnableMouse
    of mtCellMotion: EnableMouseCellMotion
    of mtAllMotion: EnableMouseAllMotion

proc disableMouse*(t: Tty) = t.write DisableMouse

proc enableBracketedPaste*(t: Tty) = t.write EnableBracketedPaste
proc disableBracketedPaste*(t: Tty) = t.write DisableBracketedPaste

proc enableFocusReporting*(t: Tty) = t.write EnableFocusReporting
proc disableFocusReporting*(t: Tty) = t.write DisableFocusReporting

proc disableLineWrap*(t: Tty) = t.write DisableLineWrap
proc enableLineWrap*(t: Tty) = t.write EnableLineWrap
