## A typing speed test.
##
## **Text compared against a target, one rune at a time.** Every other example
## that styles text styles a *run* of it — a column, a row, a matched search
## term. Here the unit is the character, because that is what the model knows:
## the state of rune `i` is whether `typed[i]` equals `target[i]`, and there is
## no larger thing to colour. That makes it the case `Spans` was shaped for, and
## the case its run-coalescing pays for: correct text is one long run of one
## style however many keystrokes built it, so a line of a hundred characters
## emits a handful of escapes rather than a hundred.
##
## Four things it carries that only exist once keystrokes are *data*:
##
## * **The wrong rune is never drawn — the target rune is drawn wrong.** Showing
##   what was typed lets a two-column rune land where a one-column rune was
##   measured, which moves every character after it and reflows the paragraph
##   mid-word. The mistake is spelled with colour, which costs no columns.
## * **`q` cannot quit**, and neither can any other printable key: it is a
##   character in the phrase. Only `ctrl+c`, `esc` and `tab` are free, which is
##   the whole binding budget.
## * **A paste is not typing.** `poBracketedPaste` is on and `PasteMsg` is
##   deliberately dropped — not for tidiness but because without the option the
##   payload arrives as keystrokes and finishes the test at several million words
##   a minute.
## * **The clock starts on the first keystroke**, not at startup, so the time
##   spent reading the phrase is not counted. `elapsed` is a field rather than a
##   `getMonoTime()` in `view`, per `stopwatch`.
##
##   nim c -r --path:src examples/typing.nim

import std/[times, strutils, unicode, random, strformat, math]
import nimtui

const
  Phrases = [
    "the quick brown fox jumps over the lazy dog while the whole town sleeps",
    "a terminal is a grid of cells and every cell holds exactly one character",
    "simplicity is a great virtue but it requires hard work to achieve it",
    "programs must be written for people to read and only incidentally for machines",
    "the cost of adding a feature is not just the time it takes to code it",
    "any sufficiently advanced bug is indistinguishable from a feature request",
    "premature optimisation is the root of all evil in programming or so we are told",
    "there are only two hard things in computer science and one of them is naming",
    "make it work then make it right and only then worry about making it fast",
    "a good name is worth more than a paragraph of comments explaining a bad one",
    "every line of code you do not write is a line you never have to debug again",
    "the fastest code is the code that never runs at all on any input you are given",
    "deleting code feels better than writing it and is usually the braver choice",
    "a test that has never failed is a test you do not yet know anything about",
    "the escape sequence goes out and the answer comes back on the same stream",
    "a rune is not a column and forgetting that will wrap your line at the edge",
    "text arrives in whatever chunks the kernel felt like giving you this morning",
    "one thread and no sleeping is a surprisingly good design for a small program",
    "the terminal was here before you and it will be here long after you are gone",
    "when the model changes the view changes and nothing else needs to know why",
    "walk the cursor back over the block you drew and redraw only what moved",
    "if you cannot explain the bug in one sentence you have not found it yet",
    "an error you can reproduce is half fixed and one you cannot is barely a bug",
    "read the code that is there before writing the code you think should be",
    "the second time you type something is the time to think about a function",
    "measure first because your intuition about speed is wrong more often than not",
  ]
  Interval = initDuration(milliseconds = 250)
  MaxSamples = 200                ## enough history for the widest sparkline

  Accent = rgb(120, 200, 255)
  Done = rgb(225, 235, 245)
  Wrong = rgb(255, 105, 105)
  Good = rgb(130, 230, 150)

type
  Phase = enum pReady, pTyping, pOver

  Model = object
    target: seq[Rune]
    typed: seq[Rune]
    strokes: int                  ## every rune key pressed, corrections included
    misses: int                   ## how many of those were the wrong rune
    phase: Phase
    startedAt: MonoTime
    elapsed: Duration
    samples: seq[float]           ## wpm, one per tick
    size: TermSize

var rng = initRand(0x7ee1)

# --- metrics ------------------------------------------------------------------

proc minutes(m: Model): float =
  m.elapsed.inMilliseconds.float / 60_000.0

proc correct(m: Model): int =
  ## Runes standing in the right place *now*, so a fixed mistake stops counting
  ## against this — which is what separates it from `misses` below.
  for i, r in m.typed:
    if r == m.target[i]: inc result

proc wpm(m: Model): float =
  ## A word is five characters, which is the convention every typing test uses:
  ## measuring real words would score a phrase of short ones higher for the same
  ## work.
  if m.minutes <= 0: 0.0 else: (m.correct.float / 5.0) / m.minutes

proc rawWpm(m: Model): float =
  ## The same rate over every keystroke, right or wrong. Above `wpm` by exactly
  ## the amount that went into typing things twice.
  if m.minutes <= 0: 0.0 else: (m.strokes.float / 5.0) / m.minutes

proc accuracy(m: Model): float =
  ## Of the keystrokes, not of the result: a phrase fixed up to be perfect was
  ## still typed wrong, and hiding that would make backspace free.
  if m.strokes == 0: 1.0
  else: (m.strokes - m.misses).float / m.strokes.float

proc progress(m: Model): float =
  if m.target.len == 0: 0.0 else: m.typed.len / m.target.len

proc sample(m: var Model) =
  # Nothing before half a second: a rate measured over two keystrokes is a
  # division by nearly zero, and one such spike rescales the whole sparkline —
  # every widget here is scaled to its own window, so a meaningless first sample
  # flattens all the real ones against the floor.
  if m.elapsed < initDuration(milliseconds = 500): return
  if m.samples.len >= MaxSamples: m.samples.delete 0
  m.samples.add m.wpm

# --- update -------------------------------------------------------------------

proc restart(m: var Model) =
  m.typed.setLen 0
  m.strokes = 0
  m.misses = 0
  m.samples.setLen 0
  m.elapsed = DurationZero
  m.phase = pReady

proc newPhrase(m: var Model) =
  m.target = Phrases[rng.rand(Phrases.high)].toRunes
  m.restart()

proc typeRune(m: var Model, r: Rune, now: MonoTime): Cmd =
  if m.phase == pOver or m.typed.len >= m.target.len: return nil
  if m.phase == pReady:
    m.phase = pTyping
    m.startedAt = now
    result = tick(Interval)       # the clock starts here, not at startup
  inc m.strokes
  if r != m.target[m.typed.len]: inc m.misses
  m.typed.add r
  if m.typed.len == m.target.len:
    m.phase = pOver
    # Measured rather than taken from the last tick: the final number is the one
    # anybody reads, and it must not be up to 250ms stale.
    m.elapsed = now - m.startedAt
    m.sample()

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)

  if msg of TickMsg:
    if m.phase == pTyping:
      result[0].elapsed = TickMsg(msg).at - m.startedAt
      result[0].sample()
      result[1] = tick(Interval)

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    # Every printable key is data, so the only bindings available are the ones a
    # phrase cannot contain.
    if k.matches("ctrl+c"):
      result[1] = quitCmd()
    elif k.matches("esc"):
      result[0].restart()
    elif k.matches("tab", "enter"):
      result[0].newPhrase()
    elif k.matches("backspace"):
      # A correction, not an edit: it drops the last rune and leaves `strokes`
      # and `misses` alone, which is what keeps `accuracy` honest.
      if m.phase != pOver and result[0].typed.len > 0:
        result[0].typed.setLen result[0].typed.len - 1
    elif k.key in {kRune, kSpace} and k.mods * {mCtrl, mAlt} == {}:
      # `kSpace` carries `Rune(' ')`, so both kinds go in through the same field.
      result[1] = result[0].typeRune(k.rune, getMonoTime())

  elif msg of PasteMsg:
    # Handled by being ignored, which is a decision rather than an omission: the
    # option is on precisely so these bytes are not keystrokes. Without it a
    # paste of the phrase would finish the test in one message.
    discard

# --- view ---------------------------------------------------------------------

proc columnsOf(runes: seq[Rune], s: Slice[int]): int =
  for i in s: result += runeWidth(runes[i])

proc wordSlices(runes: seq[Rune]): seq[Slice[int]] =
  ## A word is a run of non-spaces *plus the spaces after it*, so the separator
  ## belongs to the word it follows and a line break never loses a character the
  ## user still has to type.
  var i = 0
  while i < runes.len:
    let start = i
    while i < runes.len and runes[i] != Rune(' '): inc i
    while i < runes.len and runes[i] == Rune(' '): inc i
    result.add start .. i - 1

proc wrapRunes(runes: seq[Rune], width: int): seq[Slice[int]] =
  ## Word wrap in *rune indices* rather than in strings, because the caller has
  ## to style position `i` and needs to know which line it landed on.
  ##
  ## The trailing spaces count towards the fit, so a line is never wider than
  ## `width` — one word may wrap a column early, which is invisible, where an
  ## overflowing line drags the whole frame out of step.
  if width <= 0 or runes.len == 0: return
  var
    lineStart = 0
    cols = 0
  for w in runes.wordSlices:
    let wc = runes.columnsOf(w)
    if cols > 0 and cols + wc > width:
      result.add lineStart .. w.a - 1
      lineStart = w.a
      cols = 0
    if wc > width:
      # A word longer than the pane has to be cut somewhere; cut it at the edge
      # rather than letting it hang over.
      var c = 0
      for i in w:
        let rw = runeWidth(runes[i])
        if c + rw > width:
          result.add lineStart .. i - 1
          lineStart = i
          c = 0
        c += rw
      cols = c
    else:
      cols += wc
  if lineStart < runes.len: result.add lineStart .. runes.high

proc phraseBlock(m: Model, width: int): string =
  ## The target, one `Spans` per line, styled per rune. Four states, and the
  ## caret is the fifth thing a cell can be — `reverse`, since a component here
  ## never moves the terminal's own cursor.
  let
    pending = Style().faint()
    typedOk = Style().fg(Done)
    typedBad = Style().fg(Wrong).underline()
    caret = Style().fg(Accent).reverse()
  var lines: seq[string]
  for s in wrapRunes(m.target, width):
    var line: Spans
    for i in s:
      let glyph = $m.target[i]
      # Always the *target* rune: drawing what was typed would let a wide rune
      # land in a cell measured for a narrow one and reflow everything after it.
      if i < m.typed.len:
        line.add(glyph, if m.typed[i] == m.target[i]: typedOk else: typedBad)
      elif i == m.typed.len and m.phase != pOver:
        line.add(glyph, caret)
      else:
        line.add(glyph, pending)
    lines.add line.render()
  lines.join("\n")

proc metric(label, value: string, colour = Done): string =
  Style().faint().render(label & " ") & Style().fg(colour).bold().render(value)

proc results(m: Model, width: int): string =
  let rows = @[
    metric("wpm", &"{m.wpm.round.int}", Good) & "   " &
      metric("raw", &"{m.rawWpm.round.int}") & "   " &
      metric("accuracy", &"{(m.accuracy * 100).round.int}%",
             if m.accuracy > 0.97: Good else: Wrong),
    "",
    Style().faint().render(
      &"{m.elapsed.inMilliseconds.float / 1000.0:.1f}s · {m.target.len} " &
      &"characters · {m.misses} of {m.strokes} keystrokes wrong"),
  ]
  var centred: seq[string]
  for r in rows: centred.add centerVisible(r, width - 4)
  let body = centred.join("\n")
  # Height from the content, not a constant: a panel one row short does not look
  # cramped, it silently drops the last line — which is how the keystroke count
  # went missing here the first time.
  renderBox(body, width, blockHeight(body) + 4, title = " done ",
            border = ThickBorder, borderStyle = Style().fg(Good),
            titleStyle = Style().fg(Good).bold(), padding = 1)

proc live(m: Model, width: int): string =
  let
    inner = width - 4
    bar = gauge(m.progress, max(inner - 12, 4), CoolGradient)
    counted = Style().faint().render(&" {m.typed.len}/{m.target.len}")
    row = metric("wpm", &"{m.wpm.round.int}", Accent) & "   " &
          metric("raw", &"{m.rawWpm.round.int}") & "   " &
          metric("accuracy", &"{(m.accuracy * 100).round.int}%") & "   " &
          metric("time", &"{m.elapsed.inMilliseconds.float / 1000.0:.1f}s")
    # Two rows either way, so the panel is the same height before and after there
    # is anything to draw and the footer below it does not step down a line.
    trace =
      if m.samples.len < 2:
        "\n" & Style().faint().render("wpm over time")
      else:
        sparkline(m.samples, inner, CoolGradient) & "\n" &
        Style().faint().render(&"wpm over time · peak {m.samples.max.round.int}")
    body = joinVertical(row, "", bar & counted, "", trace)
  renderBox(body, width, blockHeight(body) + 4, title = " speed ",
            borderStyle = Style().faint(), titleStyle = Style().fg(Accent),
            padding = 1)

proc view(m: Model): string =
  if m.size.width == 0 or m.target.len == 0: return "loading…"
  let
    width = clamp(m.size.width - 4, 24, 86)
    phrase = m.phraseBlock(width - 4)
    header = Style().bold().render("  typing test  ") &
      Style().faint().render(
        case m.phase
        of pReady: "type the phrase to start the clock"
        of pTyping: &"{m.target.len - m.typed.len} to go"
        of pOver: "finished")

  joinVertical(
    header,
    "",
    renderBox(phrase, width, blockHeight(phrase) + 4,
              title = " type this ",
              borderStyle = Style().fg(if m.phase == pOver: Good else: Accent),
              titleStyle = Style().faint(), padding = 1),
    "",
    if m.phase == pOver: m.results(width) else: m.live(width),
    "",
    "  " & hints({"esc": "restart", "tab": "new phrase",
                  "ctrl+c": "quit"}))

when isMainModule:
  var m = Model()
  m.newPhrase()
  discard newProgram(m, update, view,
                     options = {poAltScreen, poHideCursor,
                                poBracketedPaste}).run()
