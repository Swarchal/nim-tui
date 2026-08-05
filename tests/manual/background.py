"""Play terminal to the background probe, and see what it makes of the answers.

    python3 tests/manual/background.py [-v]

Run by hand, not by `nimble test`, but cheap to run: it compiles `askbg.nim`
itself — a `probeBackground` and nothing else — and needs no terminal of its own.

What it covers is the half of `query` that `tests/tquery.nim` cannot reach. That
suite takes a constructed reply apart, which is everything decidable from a
string; everything else about the probe is on the wire — raw mode, the poll, the
deadline, and whether the DA1 sentinel really does end the wait when a terminal
declines to answer.

Each case is a fake terminal with exactly one behaviour, and the assertion is as
much about *how long* the probe took as about what it decided. That is the part
that fails silently: a probe returning the right answer by waiting out the
deadline every time looks correct in every other test there is.

No pyte here — nothing is being drawn, and the whole exchange is escape sequences
in both directions. The one trap from CLAUDE.md that does apply is writing whole
sequences in a single `os.write`, which is what the terminal being faked would
do.
"""
import os, pty, select, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
ASK = os.path.join(HERE, "askbg")
VERBOSE = "-v" in sys.argv

DEADLINE_MS = 250       # query.DefaultQueryDeadlineMs
STARTUP_SLACK_MS = 150  # a process still has to start, however little it does

failures = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def build():
    cmd = ["nim", "c", "--hints:off", "--path:" + os.path.join(ROOT, "src"),
           "-o:" + ASK, os.path.join(HERE, "askbg.nim")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("could not build the fixture:\n" + r.stdout + r.stderr)


def play(label, osc11_reply, answer_da1=True, under_tmux=False):
    """Run the probe against a terminal with one behaviour. Returns (answer, ms)."""
    out = os.path.join("/tmp", "askbg-" + label.replace(" ", "-") + ".out")
    if os.path.exists(out):
        os.unlink(out)

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        # The probe reads $TMUX to decide whether the sentinel can be trusted, so
        # it is set here rather than inherited: this is usually being run from
        # inside tmux, which would silently make every case the tmux case.
        for k in ("TMUX", "TMUX_PANE"):
            os.environ.pop(k, None)
        if under_tmux:
            os.environ["TMUX"] = "/tmp/not-a-real-tmux,1,0"
        os.execv(ASK, [ASK, out])

    seen = set()
    buf = b""
    started = time.time()
    while time.time() - started < 5:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            # One write per sequence, and only ever once per query.
            if b"]11;?" in buf and "osc" not in seen:
                seen.add("osc")
                if osc11_reply:
                    os.write(fd, osc11_reply)
            if b"\x1b[c" in buf and "da" not in seen:
                seen.add("da")
                if answer_da1:
                    os.write(fd, b"\x1b[?1;2c")
        if os.path.exists(out):
            break
    wall = (time.time() - started) * 1000

    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass

    if VERBOSE:
        print("    the program wrote: " + repr(buf))
    if not os.path.exists(out):
        return "(the probe never finished)", wall
    answer, ms = open(out).read().split()
    if VERBOSE:
        print("    it decided %s after %sms (wall %.0fms)" % (answer, ms, wall))
    # `askbg` times the probe itself; the wall clock includes starting a process.
    check("osc" in seen, label + ": the query reached the terminal")
    return answer, int(ms)


build()

print("a terminal that answers:")
answer, ms = play("16-bit", b"\x1b]11;rgb:1e1e/2323/2b2b\x1b\\")
check(answer == "rgb(30,35,43)", "16-bit channels read as the colour they are")
check(ms < 50, "and the answer is taken as soon as it arrives (%dms)" % ms)

answer, ms = play("8-bit BEL", b"\x1b]11;rgb:fd/f6/e3\a")
check(answer == "rgb(253,246,227)",
      "8-bit channels and a BEL terminator read the same way")

answer, ms = play("hash form", b"\x1b]11;#002b36\x1b\\")
check(answer == "rgb(0,43,54)", "the `#rrggbb` spelling is understood too")

print("a terminal that will not say:")
answer, ms = play("declines", None, answer_da1=True)
check(answer == "declined", "declining is reported as no colour")
check(ms < DEADLINE_MS - 50,
      "and the DA1 sentinel ends the wait early, not the deadline (%dms)" % ms)

answer, ms = play("silent", None, answer_da1=False)
check(answer == "declined", "a terminal answering nothing at all also declines")
check(DEADLINE_MS <= ms < DEADLINE_MS + STARTUP_SLACK_MS,
      "waiting exactly the deadline for it (%dms)" % ms)

print("under tmux, where the sentinel can arrive first and mean nothing:")
answer, ms = play("tmux declines", None, answer_da1=True, under_tmux=True)
check(answer == "declined", "declining is still reported as no colour")
check(ms >= DEADLINE_MS,
      "and the sentinel is not believed — the deadline is waited out (%dms)" % ms)

print("a reply that arrives among other input:")
answer, ms = play("noisy", b"q\x1b]11;rgb:00/00/00\x1b\\")
check(answer == "rgb(0,0,0)", "the reply is found among bytes that are not it")

print("not a terminal at all:")
out = "/tmp/askbg-pipe.out"
subprocess.run([ASK, out], stdin=subprocess.DEVNULL, capture_output=True)
answer, ms = open(out).read().split()
check(answer == "declined" and int(ms) == 0,
      "a pipe is not asked, and costs nothing to not ask")

print()
if failures:
    print("%d failed:" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("all good")
