"""Kill a program that owns the terminal, and see what state it leaves behind.

    python3 tests/manual/signals.py [-v]

Run by hand, not by `nimble test`, but cheap: it compiles `signalled.nim` itself
— a program that renders a line and waits — and drives it under a pty.

What it covers that no unit test can. `tests/ttty.nim` asserts the bytes the
restore *would* write, which is everything decidable from a string. Everything
else is on the wire: whether the handler runs at all, whether raw mode is
actually undone, and whether the process still looks killed afterwards.

Three assertions per case, and they fail in very different ways:

* the teardown escapes appear after the last frame — visible, and the one a
  human would notice;
* `tcgetattr` shows ECHO and ICANON back on — *this is the bug*. Everything else
  can be right while the shell that comes back is unusable without `reset`;
* the process is reported as killed by the signal that killed it. This is the
  half that fails silently: a handler that restores and then exits 0 looks
  perfect here and breaks every shell trap and service manager watching it.

No pyte: nothing needs reconstructing, since the question is about the tail of
the stream and the state of the tty, not about what is on screen.
"""
import os, pty, select, signal, subprocess, sys, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
PROG = os.path.join(HERE, "signalled")
VERBOSE = "-v" in sys.argv

# Kept in step with nimtui/ansi by hand; ttty.nim is what pins them in Nim.
END_SYNC = b"\x1b[?2026l"
SHOW_CURSOR = b"\x1b[?25h"
EXIT_ALT = b"\x1b[?1049l"
DISABLE_MOUSE = b"\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l"
DISABLE_PASTE = b"\x1b[?2004l"
DISABLE_FOCUS = b"\x1b[?1004l"
RESET = b"\x1b[0m"

failures = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def build():
    cmd = ["nim", "c", "--hints:off", "--path:" + os.path.join(ROOT, "src"),
           "-o:" + PROG, os.path.join(HERE, "signalled.nim")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("could not build the fixture:\n" + r.stdout + r.stderr)


def play(sig, modes):
    """Start the program, let it draw, signal it. Returns (tail, attrs, status)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(PROG, [PROG] + modes)

    # Let it get through setup and a few frames, so there is a block on screen
    # and the terminal is definitely in raw mode.
    buf = b""
    deadline = time.time() + 2
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        if len(buf) > 200 and time.time() > deadline - 1.5:
            break

    raw = termios.tcgetattr(fd)
    before = len(buf)
    os.kill(pid, sig)

    # Drain whatever the handler writes on its way out.
    deadline = time.time() + 2
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk

    _, status = os.waitpid(pid, 0)
    attrs = termios.tcgetattr(fd)
    try:
        os.close(fd)
    except OSError:
        pass

    tail = buf[before:]
    if VERBOSE:
        print("    after the signal: " + repr(tail))
    return tail, raw, attrs, status


def cooked(attrs):
    lflag = attrs[3]
    return bool(lflag & termios.ECHO) and bool(lflag & termios.ICANON)


def case(name, sig, modes, expect):
    print("%s, killed by %s:" % (name, signal.Signals(sig).name))
    tail, raw, attrs, status = play(sig, modes)

    check(not cooked(raw), "  the program really had the terminal in raw mode")

    for label, seq in expect:
        check(seq in tail, "  " + label)
    check(tail.startswith(END_SYNC),
          "  synchronised output is ended first")

    # The one that matters: everything else can be right and the shell still
    # unusable without `reset`.
    check(cooked(attrs), "  ECHO and ICANON are back on")

    check(os.WIFSIGNALED(status), "  the process is reported as killed")
    check(os.WIFSIGNALED(status) and os.WTERMSIG(status) == sig,
          "  by %s, so the exit status stays honest"
          % signal.Signals(sig).name)


build()

case("everything on", signal.SIGTERM,
     ["alt", "cursor", "mouse", "paste", "focus"],
     [("the alt screen is left", EXIT_ALT),
      ("mouse reporting is turned off", DISABLE_MOUSE),
      ("bracketed paste is turned off", DISABLE_PASTE),
      ("focus reporting is turned off", DISABLE_FOCUS),
      ("the cursor is shown again", SHOW_CURSOR),
      ("colour is reset", RESET)])

case("in the scrollback", signal.SIGTERM, ["cursor"],
     [("the cursor is shown again", SHOW_CURSOR),
      ("colour is reset", RESET),
      ("the cursor ends on a fresh line", b"\r\n")])

case("the window closed", signal.SIGHUP, ["alt", "cursor"],
     [("the alt screen is left", EXIT_ALT),
      ("the cursor is shown again", SHOW_CURSOR)])

# ISIG is off in raw mode, so ctrl+c never produces one of these — an arriving
# SIGINT came from an explicit kill and means terminate.
case("interrupted", signal.SIGINT, ["alt"],
     [("the alt screen is left", EXIT_ALT)])

case("quit", signal.SIGQUIT, ["mouse"],
     [("mouse reporting is turned off", DISABLE_MOUSE)])

print()
if failures:
    print("%d failed:" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("all good")
