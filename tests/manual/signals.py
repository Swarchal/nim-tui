"""Every way a program stops owning the terminal, and what state it leaves it in.

Killed, stopped with ctrl+z, or handing it to a child process — three routes out
of raw mode, and the assertions are largely the same ones because the failure is:
the terminal is left in a state its next user cannot work in.

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
ENABLE_WRAP = b"\x1b[?7h"
RESET = b"\x1b[0m"
ENTER_ALT = b"\x1b[?1049h"
HIDE_CURSOR = b"\x1b[?25l"
DISABLE_WRAP = b"\x1b[?7l"

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


def play_split(sig, modes):
    """As `play`, but with input and output on two different ttys.

    `run` takes them as two parameters, so this is a shape the API invites, and
    it is the only one that can tell whether the armed restore knows which is
    which: under `pty.fork` alone fd 0 and fd 1 are the same device, so a handler
    writing its escapes to the input side passes every other case in this file.

    Returns (out_tail, in_tail, attrs, status) — the escapes belong in the first
    and the raw-mode `Termios` belongs to the tty behind the second.
    """
    out_master, out_slave = pty.openpty()
    out_name = os.ttyname(out_slave)

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.close(out_master)
        os.close(out_slave)
        os.execv(PROG, [PROG] + modes + ["out:" + out_name])
    os.close(out_slave)

    def drain(until, into):
        while time.time() < until:
            r, _, _ = select.select([fd, out_master], [], [], 0.05)
            for ready in r:
                try:
                    chunk = os.read(ready, 65536)
                except OSError:
                    continue
                into[ready] += chunk

    bufs = {fd: b"", out_master: b""}
    drain(time.time() + 1.5, bufs)

    before = {k: len(v) for k, v in bufs.items()}
    os.kill(pid, sig)
    drain(time.time() + 1.5, bufs)

    _, status = os.waitpid(pid, 0)
    attrs = termios.tcgetattr(fd)
    for handle in (fd, out_master):
        try:
            os.close(handle)
        except OSError:
            pass

    out_tail = bufs[out_master][before[out_master]:]
    in_tail = bufs[fd][before[fd]:]
    if VERBOSE:
        print("    output tty after the signal: " + repr(out_tail))
        print("    input tty after the signal:  " + repr(in_tail))
    return out_tail, in_tail, attrs, status


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

    # Not in any `expect` list because no option turns it on: the library
    # disables auto-wrap for every program, so every teardown must put it back.
    # A shell that inherits a terminal with DECAWM off is nearly as broken as one
    # that inherits it without ECHO, and nothing else here would notice.
    check(ENABLE_WRAP in tail, "  auto-wrap is turned back on")

    # The one that matters: everything else can be right and the shell still
    # unusable without `reset`.
    check(cooked(attrs), "  ECHO and ICANON are back on")

    check(os.WIFSIGNALED(status), "  the process is reported as killed")
    check(os.WIFSIGNALED(status) and os.WTERMSIG(status) == sig,
          "  by %s, so the exit status stays honest"
          % signal.Signals(sig).name)


def spawn_job(modes):
    """Start the fixture the way a job control shell would, under a pty.

    Two forks. A `pty.fork` child is a session leader, so its process group has
    no parent process in the same session — it is *orphaned*, and the kernel
    discards stop signals sent to an orphaned process group. Under a plain
    `pty.fork` the fixture never stops at all, and a suspend case measures
    nothing while every assertion in it passes.

    So the pty child plays the shell: it forks the program into a process group
    of its own and hands it the terminal with `tcsetpgrp`, which is what job
    control is and the only arrangement in which ctrl+z means anything. The
    driver is then a grandparent and cannot `waitpid`, so the pty child reports
    the final status down a pipe.

    Returns (pty_child_pid, master_fd, program_pid, pipe_reader). The reader
    yields the program's pid first and its wait status once it exits.
    """
    r_fd, w_fd = os.pipe()
    pid, fd = pty.fork()
    if pid == 0:
        os.close(r_fd)
        os.environ["TERM"] = "xterm-256color"
        gpid = os.fork()
        if gpid == 0:
            os.close(w_fd)
            os.setpgid(0, 0)
            # Handing the terminal to a background process group raises SIGTTOU
            # at the process doing the handing, which is this one.
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            os.tcsetpgrp(0, os.getpgid(0))
            os.execv(PROG, [PROG] + modes)
        os.write(w_fd, b"%d\n" % gpid)
        _, st = os.waitpid(gpid, 0)
        os.write(w_fd, b"%d\n" % st)
        os._exit(0)
    os.close(w_fd)
    reader = os.fdopen(r_fd)
    return pid, fd, int(reader.readline()), reader


def process_state(pid):
    """The single-letter state from /proc: `T` is stopped, `R`/`S` running.

    Read rather than waited for, because the driver is not this process's
    parent — see `play_suspend`. Linux-only, like nothing else in this file, and
    the alternative is relaying every status through the pipe.
    """
    with open("/proc/%d/stat" % pid) as f:
        return f.read().rsplit(")", 1)[1].split()[0]


def await_state(pid, want, seconds=2.0):
    until = time.time() + seconds
    while time.time() < until:
        try:
            if process_state(pid) == want:
                return True
        except OSError:
            return False
        time.sleep(0.02)
    return False


def play_suspend(modes, via_key, sig=signal.SIGTSTP):
    """Stop the program, continue it, stop it again, then kill it.

    **Two forks, and the second one is not incidental.** A `pty.fork` child is a
    session leader, so its process group has no parent process in the same
    session — it is *orphaned*, and the kernel discards stop signals sent to an
    orphaned process group so that nothing can be left stopped with nobody able
    to continue it. Under a plain `pty.fork` the program therefore never stops
    at all, and this whole case would be measuring the wrong thing while looking
    like it worked.

    So the pty child plays the part of the shell: it forks the program into a
    process group of its own and hands it the terminal, which is what a real job
    control shell does and is the only arrangement in which ctrl+z means
    anything. The pty child then waits, and reports the final status down a pipe
    because the driver is a grandparent and cannot `waitpid`.

    Stopping twice is also on purpose. The handler disarms itself in order to
    re-raise under the default disposition, so something has to put it back — if
    nothing does, the *first* stop looks perfect and the second takes the
    default action and leaves the terminal exactly as this exists to prevent.

    Returns a dict of the buffer slices and the tty state at each step.
    """
    pid, fd, gpid, reader = spawn_job(modes)

    buf = b""

    def drain(seconds):
        nonlocal buf
        until = time.time() + seconds
        while time.time() < until:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk

    drain(1.0)
    out = {"raw_running": termios.tcgetattr(fd), "gpid": gpid}

    def stop():
        mark = len(buf)
        if via_key:
            os.write(fd, b"z")
        else:
            os.kill(gpid, sig)
        stopped = await_state(gpid, "T")
        drain(0.3)
        return stopped, buf[mark:]

    def go():
        mark = len(buf)
        os.kill(gpid, signal.SIGCONT)
        drain(0.6)
        return buf[mark:]

    out["stopped1"], out["tail1"] = stop()
    out["attrs_stopped"] = termios.tcgetattr(fd)
    out["resume1"] = go()
    out["attrs_resumed"] = termios.tcgetattr(fd)

    out["stopped2"], out["tail2"] = stop()
    out["attrs_stopped2"] = termios.tcgetattr(fd)
    out["resume2"] = go()

    mark = len(buf)
    os.kill(gpid, signal.SIGTERM)
    drain(1.0)
    out["tail_final"] = buf[mark:]
    out["status"] = int(reader.readline())
    out["attrs_final"] = termios.tcgetattr(fd)
    os.waitpid(pid, 0)
    reader.close()
    try:
        os.close(fd)
    except OSError:
        pass
    if VERBOSE:
        for k in ("tail1", "resume1", "tail2", "tail_final"):
            print("    %s: %s" % (k, repr(out[k])))
    return out


def play_exec(child, modes, interrupt=None, key=b"e"):
    """Press the key that runs a child, and watch the terminal change hands.

    `interrupt` is a signal to send *while the child is running*, which is where
    the policy lives: those keys belong to the child for its lifetime, so a
    parent that acts on them is drawing over a screen it does not own.

    Returns a dict of the buffer slices and the tty state at each step.
    """
    pid, fd, gpid, reader = spawn_job(modes + ["exec:" + child])
    buf = b""

    def drain(seconds):
        nonlocal buf
        until = time.time() + seconds
        while time.time() < until:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk

    drain(1.0)
    out = {"raw_running": termios.tcgetattr(fd)}

    mark = len(buf)
    os.write(fd, key)
    # Long enough to be inside the child, for the cases whose child sleeps.
    time.sleep(0.4)
    out["attrs_child"] = termios.tcgetattr(fd)
    out["state_child"] = process_state(gpid)

    if interrupt is not None:
        os.kill(gpid, interrupt)
        time.sleep(0.4)
        out["state_interrupted"] = process_state(gpid)
        if interrupt == signal.SIGTSTP:
            os.kill(gpid, signal.SIGCONT)

    drain(2.5)
    out["during"] = buf[mark:]
    out["attrs_after"] = termios.tcgetattr(fd)
    out["alive"] = process_state(gpid) not in ("?", "Z")

    mark = len(buf)
    os.kill(gpid, signal.SIGTERM)
    drain(1.0)
    out["status"] = int(reader.readline())
    out["attrs_final"] = termios.tcgetattr(fd)
    os.waitpid(pid, 0)
    reader.close()
    try:
        os.close(fd)
    except OSError:
        pass
    if VERBOSE:
        print("    while and after the child: " + repr(out["during"]))
    return out


def exec_case(name, child, modes, expect_in_output, key=b"e"):
    print("%s:" % name)
    r = play_exec(child, modes, key=key)

    check(not cooked(r["raw_running"]), "  the program had the terminal in raw mode")

    # The handover. Not sampled from here with `tcgetattr`: these children finish
    # in milliseconds, so any poll of the driver's is a race it usually loses.
    # The first case has the child report its own terminal instead, which is
    # better evidence anyway — from inside, on the fd it was handed.
    check(EXIT_ALT in r["during"], "  the alt screen is left before the child runs")
    check(ENABLE_WRAP in r["during"], "  and auto-wrap is turned back on for it")

    for label, text in expect_in_output:
        check(text in r["during"], "  " + label)

    # And the taking back, which is `resumeTerminal` — the same proc a resume
    # from ctrl+z uses, which is most of why this was cheap to add.
    check(not cooked(r["attrs_after"]), "  raw mode is retaken when the child exits")
    check(ENTER_ALT in r["during"], "  the alt screen is re-entered")
    check(b"holding the terminal" in r["during"], "  and the frame is redrawn")

    check(cooked(r["attrs_final"]), "  ECHO and ICANON are back on at exit")
    check(os.WIFSIGNALED(r["status"]) and os.WTERMSIG(r["status"]) == signal.SIGTERM,
          "  and the exit status is still honest")


def exec_signal_case(name, sig, expect_stopped):
    """A signal arriving while the child owns the terminal."""
    print("%s:" % name)
    r = play_exec("sleep 1.5", ["alt", "cursor"], interrupt=sig)

    check(r["state_child"] in ("S", "R"), "  the program is waiting on the child")
    # Sampled mid-child for real here, the child being one that sleeps.
    check(cooked(r["attrs_child"]),
          "  the child holds a cooked terminal while it runs")
    if expect_stopped:
        # Ctrl+z should background the whole job: the child inherits the
        # program's process group, so the terminal signals both.
        check(r["state_interrupted"] == "T",
              "  the whole job stops, rather than only one half of it")
    else:
        check(r["state_interrupted"] in ("S", "R"),
              "  the program does not die on a key that belongs to the child")

    check(r["alive"], "  the program is still running afterwards")
    check(not cooked(r["attrs_after"]), "  and has the terminal back in raw mode")
    check(b"child exited 0" in r["during"], "  the child ran to completion")
    check(cooked(r["attrs_final"]), "  ECHO and ICANON are back on at exit")


def stopped_case(name, modes):
    """SIGSTOP, which cannot be caught, so no handler runs and nothing is restored.

    Everything here is about the resume taking the *other* branch. The terminal
    was never handed back, so it must not be re-entered from scratch: doing that
    saves the raw settings as the ones to put back at exit, and the run then ends
    by handing the shell a raw terminal — having looked correct at every earlier
    step, including every check in the SIGTSTP cases above.
    """
    print("%s:" % name)
    r = play_suspend(modes, via_key=False, sig=signal.SIGSTOP)

    check(r["stopped1"], "  the process stops, there being no handler to argue")
    check(not cooked(r["attrs_stopped"]),
          "  the terminal is still raw while stopped, since nothing restored it")
    check(not cooked(r["attrs_resumed"]), "  and still raw after the continue")
    check(b"holding the terminal" in r["resume1"], "  the frame is redrawn anyway")

    # The one this case exists for.
    check(cooked(r["attrs_final"]),
          "  ECHO and ICANON are back on at exit, so the saved settings survived")
    check(os.WIFSIGNALED(r["status"]) and os.WTERMSIG(r["status"]) == signal.SIGTERM,
          "  and the exit status is still honest")


def suspend_case(name, modes, via_key):
    print("%s:" % name)
    r = play_suspend(modes, via_key)

    check(not cooked(r["raw_running"]),
          "  the program really had the terminal in raw mode")

    # The half that fails silently in the other direction from the terminate
    # cases: a handler that puts the terminal back and then *carries on running*
    # leaves every check below looking right, and ctrl+z simply does nothing.
    check(r["stopped1"], "  the process actually stops")

    check(r["tail1"].startswith(END_SYNC),
          "  synchronised output is ended before stopping")
    check(EXIT_ALT in r["tail1"], "  the alt screen is left on the way down")
    check(ENABLE_WRAP in r["tail1"], "  auto-wrap is turned back on")

    # The same assertion the terminate cases call *the* bug, and it matters more
    # here: a shell is about to be typed at, and the program means to come back.
    check(cooked(r["attrs_stopped"]), "  ECHO and ICANON are back on while stopped")

    check(not cooked(r["attrs_resumed"]), "  raw mode is taken again on resume")
    check(ENTER_ALT in r["resume1"], "  the alt screen is re-entered")
    check(DISABLE_WRAP in r["resume1"], "  auto-wrap is turned off again")
    check(b"holding the terminal" in r["resume1"],
          "  the frame is redrawn rather than diffed against a screen a shell used")

    check(r["stopped2"], "  a second stop still stops")
    check(cooked(r["attrs_stopped2"]),
          "  and still puts the terminal back, so the handler was reinstalled")

    check(cooked(r["attrs_final"]), "  ECHO and ICANON are back on after the kill")
    check(os.WIFSIGNALED(r["status"]) and os.WTERMSIG(r["status"]) == signal.SIGTERM,
          "  and the exit status is still honest")


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


def split_case(name, sig, modes, expect):
    print("%s, killed by %s:" % (name, signal.Signals(sig).name))
    out_tail, in_tail, attrs, status = play_split(sig, modes)

    for label, seq in expect:
        check(seq in out_tail, "  " + label + ", on the tty being drawn to")
        check(seq not in in_tail, "  and not on the one being read from")

    # The other half of the same confusion: raw mode was set on the input side,
    # so that is where the saved settings have to go back. Putting them on the
    # output tty restores nothing and modifies a terminal never touched.
    check(cooked(attrs), "  ECHO and ICANON are back on the input tty")

    check(os.WIFSIGNALED(status) and os.WTERMSIG(status) == sig,
          "  killed by %s, so the exit status stays honest"
          % signal.Signals(sig).name)


suspend_case("stopped from outside", ["alt", "cursor", "mouse"], via_key=False)
suspend_case("suspended by the program itself", ["alt", "cursor"], via_key=True)
stopped_case("stopped with SIGSTOP, which no handler sees", ["alt", "cursor"])

exec_case("handing the terminal to a child", "stty -a | tr '\\n' ' '",
          ["alt", "cursor"],
          [("the child sees echo on", b" echo"),
           ("the child sees canonical mode on", b" icanon"),
           ("the exit status comes back", b"child exited 0")])

exec_case("a child that fails is not an error, and says so", "exit 3",
          ["alt"], [("its exit code is reported as it stands", b"child exited 3")])

# `x` runs a binary that does not exist and passes no `then`, which is the one
# path where a failure has nowhere to go but `ErrorMsg` — and the one that would
# otherwise be a program that flickered and did nothing.
exec_case("a binary that does not exist becomes an ErrorMsg", "true", ["alt"],
          [("the failure is reported", b"error: nimtui-no-such-binary")],
          key=b"x")

# ISIG is back on while the child has the terminal, so both of these reach the
# whole foreground process group — the child and the program alike.
exec_signal_case("interrupted while the child owns the screen",
                 signal.SIGINT, expect_stopped=False)
exec_signal_case("ctrl+z while the child owns the screen",
                 signal.SIGTSTP, expect_stopped=True)

split_case("input and output on different ttys", signal.SIGTERM,
           ["alt", "cursor", "mouse"],
           [("the alt screen is left", EXIT_ALT),
            ("the cursor is shown again", SHOW_CURSOR),
            ("mouse reporting is turned off", DISABLE_MOUSE)])

print()
if failures:
    print("%d failed:" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("all good")
