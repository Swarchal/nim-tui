# nimtui

A Nim library for creating TUI applications.

Inspired by charm and bubbletea libraries in Go: state lives in one model, all
changes go through `update`, and `view` is a pure function that returns the
frame as a string. The runtime owns the terminal, turns input into messages and
redraws when the view changes.

```nim
import nimtui

type Model = object
  count: int

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  if msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("up"): result[0].count.inc
    elif k.matches("down"): result[0].count.dec

proc view(m: Model): string =
  "count: " & $m.count & "\n(up/down to change, q to quit)"

when isMainModule:
  discard newProgram(Model(), update, view).run()
```

## Install

```sh
nimble install https://github.com/swarchal/nim-tui
```

Requires Nim 2.0 or newer. POSIX only for now — raw mode and terminal sizing
live in `src/nimtui/tty.nim`, which is the only module a port needs to replace.

## Concepts

| Piece | What it is |
| --- | --- |
| **Model** | Any type. Treated as a value; the runtime holds the current one. |
| **Msg** | An event. Inherit from `Msg` to add your own. |
| **Cmd** | `proc (): Msg` — a side effect whose result re-enters `update`. |
| **update** | `(Model, Msg) -> (Model, Cmd)`. The only place state changes. |
| **view** | `Model -> string`. Pure; lines are separated by `\n`. |

Messages the runtime produces: `KeyMsg`, `MouseMsg`, `WindowSizeMsg`,
`ErrorMsg` (a command raised) and `TickMsg` (a timer fired), plus `PasteMsg`,
`FocusMsg` and `TerminalBgMsg` behind the options that ask the terminal for
them. `OscMsg` needs no option and can arrive at any time: it is the terminal
answering a question, which anything else sharing it can have asked.

`k.matches("q", "ctrl+c")` is how a key is bound. Names are `a`, `enter`,
`ctrl+c`, `alt+up`, `shift+tab`, `f5` — and they are read at compile time, so a
spec that names no key stops the build instead of quietly never matching:

```nim
if k.matches("pgdn"): …    # Error: bad key spec "pgdn": no key is named "pgdn"
if k.matches("ctrl+W"): …  # Error: … a control character decodes to its
                           # lower-case letter: write "ctrl+w"
```

That is the whole reason it exists. A misspelled binding is otherwise invisible
until someone presses that exact key, which no test catches and no compiler
mentions. `$KeyMsg` still gives the same name as a string, for logging and for
showing a user what they pressed.

Commands: `quitCmd()`, `msgCmd(m)`, `batch(a, b, …)`, `after(duration, msg)`,
`tick(duration)`, `execCmd(command, args, then)`, `suspendCmd()`. Return `nil`
for no effect. Repeating work re-issues `tick` from `update` each time it fires.

Options are a `set[ProgramOption]` passed to `newProgram`:

| | |
| --- | --- |
| `poAltScreen` | draw on the alternate screen buffer |
| `poHideCursor` | hide the cursor for the duration of the program |
| `poMouseClicks` | report button presses, releases and the wheel |
| `poMouseCellMotion` | also report motion while a button is held |
| `poMouseAllMotion` | also report motion with no button held |
| `poBracketedPaste` | deliver a paste as one `PasteMsg` rather than as its characters typed one at a time |
| `poFocusReporting` | deliver a `FocusMsg` when the window gains or loses focus |
| `poQueryBackground` | ask the terminal its background colour, delivered as a `TerminalBgMsg` before the first frame |

The three mouse levels are points on a scale rather than separate requests, so
asking for several selects the most detailed. The wheel is reported at *every*
level — xterm sends it as a button press rather than as motion — so an
application that only scrolls wants `poMouseClicks`, not a motion level feeding
an `else: discard`.

Two of these have a contract worth knowing before turning them on.
**`poBracketedPaste` means `PasteMsg` has to be handled, or pasted text is
discarded.** Without the option a pasted newline arrives as `kEnter`, which
submits a form halfway through the paste; with it and no handler, the paste is
dropped instead — so the choice is the program's either way. And
`poQueryBackground` answers `ckDefault` when the terminal will not say, which is
the normal case on a terminal that does not implement OSC 11 rather than an
error: a palette that cannot cope without an answer should not be asking.
Ignoring a `FocusMsg` costs nothing.

The terminal is put back on every way out the library can see: a normal return,
an exception, a terminating signal, ctrl+z, and handing it to another program.

`execCmd("git", ["commit"], then)` restores the terminal, runs the child on it,
and takes it back and repaints when the child exits — `$EDITOR`, a pager,
anything wanting the screen. `then` receives the exit code, or an error if the
child could not be started at all. No concurrency: commands already run
synchronously between updates, so a child process is just a very long one.

Ctrl+z is two halves. A `SIGTSTP` arriving from outside is handled
unconditionally, because its default action would stop the process with the
terminal in raw mode and hand the shell back unusable; binding ctrl+z *itself* is
`suspendCmd()`, and is the application's call, since raw mode clears `ISIG` and
ctrl+z reaches `update` as an ordinary key.

## Building a view

A *block* is just a string with `\n` between its lines - the same thing `view`
returns - so blocks compose with each other and with ordinary text. Everything
measures in columns rather than bytes or runes, so styled and double-width text
lines up.

```nim
let left  = renderBox("cpu\n" & gauge(0.62, 16), 20, 6, title = "host")
let right = renderBox(sparkline(samples, 16), 20, 6, title = "requests")
joinVertical(joinHorizontal([left, right], gap = 1),
             hints({"space": "pause", "q": "quit"}))
```

`nimtui/layout` - `renderBox` with a `Border`, `padBlock` / `padBlockLines`,
`joinHorizontal` / `joinVertical`, `elide`, `centerVisible`, `blockWidth` /
`blockHeight`. `ruledBorder(lwDouble, lwThin)` builds a border whose interior
rules are lighter than its frame, junctions and all, and `gradientFill` draws an
angled gradient as a block to `place` a dialog on.

`nimtui/boxdraw` - box-drawing glyphs as an algebra: four arms at four weights
into one glyph, and `combine` to lay one line over another.

`nimtui/ansi` - the measuring and cutting helpers every other module is built
on: `displayWidth`, `truncateVisible`, `sliceVisible`, `padVisible`, plus
`oneLine` and `expandTabs` for text that came from a file or another program and
would otherwise be drawn wider than it was measured. `nimtui/width` adds
`columnOf` / `runeAtColumn` for text held as runes, which is what a cursor or a
click needs.

`nimtui/digits` - numerals three rows tall, in a thin and a bold set.

`nimtui/widgets` - `gauge`, `thinBar`, `sparkline`, `barChart`, `spinner`,
`pulse`, `keyHint`, `hints`. Each returns exactly the width asked for, using
partial block glyphs so a bar resolves an eighth of a cell.

None of these touches a terminal or depends on the runtime, so they can be used
on their own - and `update`/`view` can be tested without either.

## Examples

```sh
nimble examples          # builds all of them into bin/
```

Start here:

| | |
| --- | --- |
| `counter` | the program above, and nothing else |
| `stopwatch` | one repeating timer via `tick` |
| `keys` | input debugger - shows how each keystroke, mouse event and resize decodes |

Then the ones that exercise the runtime properly:

| | What it is really about |
| --- | --- |
| `filebrowser` | IO inside commands. A command that raises becomes an `ErrorMsg`, so an unreadable directory shows up on the status line instead of unwinding the loop — try `./bin/filebrowser /root`. Also: scrolling viewport, split panes that drop the preview below 80 columns, and `e` to open the selection in `$EDITOR` via `execCmd` |
| `todo` | A model with modes. `update` dispatches on `m.mode` before the key, which is what stops a text field swallowing `q`. Also: live filtering where the cursor tracks the filtered list, and flash messages that expire via `after` |
| `dashboard` | Three concurrent timers at different rates (90ms spinner, 400ms sample, 1.2s log), each re-arming itself, none blocking the others. Also: a 2x2 grid that collapses to one column when narrow |
| `snake` | A game loop whose tick rate changes with the score. Ticks are stamped with a generation so stale ones are dropped rather than double-stepping, and turns are buffered until the step so mashing keys cannot fold the snake into itself |
| `vim` | A key whose meaning depends on the keys before it. Modal editing is the smallest realistic thing that cannot be written as a flat list of bindings, and what replaces it is three fields - the mode, the count typed so far, and the keys of a command that is not finished yet. It is also the one example that still builds `$k` into a string, because every key is appended to the pending command and the result looked up whole. Also what an application owns when the library stops: there is no editable multi-line component, so the buffer and the cursor are the model's |

The stateful components - `TextInput`, `TextArea`, `ListView`, `Viewport` - are
library modules, tested in `tests/tcomponents.nim`, `tests/tlistview.nim` and
`tests/ttextarea.nim`. Each one's `handleKey` returns whether it wanted the key,
so a view can offer a key to whatever has focus and treat the refusals as its
own.

## Testing your own programs

`runHeadless` drives the real update loop over a list of messages with no
terminal attached, so update procs can be tested directly:

```nim
let final = newProgram(Model(), update, view).runHeadless(@[
  Msg(KeyMsg(key: kUp)),
  Msg(KeyMsg(key: kUp)),
])
check final.count == 2
```

Timers are delivered immediately in scheduled order rather than waited on, so
tests stay deterministic - including anything `initCmd` scheduled, which arrives
before the first message just as it would with a real terminal.

A repeating timer never runs out, so delivery is capped by `maxTimers`. Set it to
the number of ticks the test wants:

```nim
let final = newProgram(Model(), update, view,
                       initCmd = tick(initDuration(milliseconds = 100)))
  .runHeadless(@[], maxTimers = 3)
check final.ticks == 3
```

## Development

```sh
nimble test                      # whole suite
nim c -r tests/tinput.nim        # one file
nimble docs                      # API docs into htmldocs/
```

## Status

Early. The pieces below are in place and tested; the runtime is single-threaded,
so commands run synchronously between updates - long-running effects block
rendering until they return.

Widths are column-accurate: `runeWidth` classifies East Asian Wide/Fullwidth and
emoji as two cells and combining marks as zero, so CJK text lays out correctly in
boxes and text fields. Grapheme clusters are not - emoji ZWJ sequences and `❤️`
(base plus variation selector) still measure per rune.

Redraws are per-line. Only lines that differ from what is on screen are
rewritten, each one is written before its tail is erased rather than after, and a
frame is wrapped in synchronized-output markers where the terminal supports them.
A view that changes 20 times a second for one moving spinner costs a couple of
lines per frame instead of a full repaint, which is what keeps it from flickering.

**Commands are synchronous, deliberately.** A threadpool was built and then
reverted: under Nim's default `--mm:orc`, an object carrying a closure cannot
safely round-trip between threads, and `Msg` - an inheriting ref - has the same
problem. The failure is a segfault inside the garbage collector, and the
constraint can't be caught at compile time, so it isn't a trade worth making
here. `tests/manual/orc_closure_threads.nim` reproduces it in 20 lines of
difference, and `CLAUDE.md` records the measurements.

For work slow enough to drop a frame, do it in slices: a bounded chunk per
command, returning a message that re-issues the next chunk with
`after(DurationZero, …)`. The loop handles input and redraws in between.

Not yet done, in rough order of how much is missing:

* **Cursor positioning from `view`.** Every cursor here is a reversed cell drawn
  into the frame, with the terminal's own hidden - which is what keeps the
  renderer in sole charge of it. What that costs is a cursor shape (a bar in
  insert, a block in normal), and anything that follows the real cursor: a
  screen reader, an IME's preedit. Fixing it means `view` gaining somewhere to
  put a position, so it is a runtime change rather than a widget one.
* **An editable multi-line buffer.** `TextArea` is read-only and `TextInput` is
  one line; `examples/vim.nim` shows what an application currently has to own
  itself between them.
* **Windows support.** `src/nimtui/tty.nim` is POSIX and fails to compile
  elsewhere by design; it is the only module a port needs to replace.

## Licence

MIT
