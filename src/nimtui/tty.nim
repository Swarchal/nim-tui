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
    ieTimeout    ## nothing arrived before the timeout elapsed
    ieReadable   ## bytes are waiting to be read
    ieClosed     ## the input stream hung up

  WinSize {.importc: "struct winsize", header: "<sys/ioctl.h>", final, pure.} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

var TIOCGWINSZ {.importc, header: "<sys/ioctl.h>".}: cuint
  ## SIGWINCH is not in POSIX, so std/posix does not declare it.
var SIGWINCH {.importc, header: "<signal.h>".}: cint

var resizePending: bool

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
  if n <= 0: return ieTimeout
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

proc enableMouse*(t: Tty, allMotion = false) =
  ## Turn on SGR mouse reporting: motion while a button is held, or all motion.
  ##
  ## Here rather than at the caller for the same reason as the toggles above —
  ## this module is meant to be the only one a port has to reimplement, so which
  ## escape sequence a mode maps to is decided in one place.
  t.write(if allMotion: EnableMouseAllMotion else: EnableMouseCellMotion)

proc disableMouse*(t: Tty) = t.write DisableMouse
