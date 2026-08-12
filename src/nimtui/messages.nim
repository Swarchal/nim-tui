## The message and command vocabulary shared by every layer.
##
## `Msg` is an open ref hierarchy: the runtime defines the messages it produces
## (keys, mouse, resize) and applications add their own by inheriting from
## `Msg`. Update procs discriminate with `msg of MyMsg`.
##
## A `Cmd` is a deferred side effect. The runtime runs it and feeds whatever
## `Msg` it returns back through `update`, which is how effects re-enter the
## pure part of the program. Returning `nil` means "no follow-up message".

import std/[monotimes, times, unicode, strutils, macros]
import ./color

# MonoTime and Duration appear in the public message types, so callers need
# them without a second import. `color` is here for the same reason —
# `TerminalBgMsg` carries one — and costs no layering: `color` is pure
# arithmetic with no dependencies of its own.
export monotimes, Duration, initDuration, DurationZero
export color

type
  Msg* = ref object of RootObj
    ## Base type for everything that can be delivered to `update`.

  Cmd* = proc (): Msg {.closure.}
    ## A side effect to be performed by the runtime. May return nil.

  Key* = enum
    kNone, kRune, kSpace, kEnter, kTab, kShiftTab, kBackspace, kEsc,
    kUp, kDown, kRight, kLeft,
    kHome, kEnd, kPgUp, kPgDown, kInsert, kDelete,
    kF1, kF2, kF3, kF4, kF5, kF6, kF7, kF8, kF9, kF10, kF11, kF12

  Modifier* = enum
    mShift, mAlt, mCtrl

  KeyMsg* = ref object of Msg
    ## A keypress. For `kRune` the character is in `rune`; named keys leave it
    ## at `Rune(0)`. `ctrl+c` arrives as `kRune` `'c'` with `mCtrl` set.
    key*: Key
    rune*: Rune
    mods*: set[Modifier]

  MouseButton* = enum
    mbNone, mbLeft, mbMiddle, mbRight, mbWheelUp, mbWheelDown

  MouseAction* = enum
    maPress, maRelease, maMotion

  MouseMsg* = ref object of Msg
    ## Mouse event with 1-based cell coordinates.
    x*, y*: int
    button*: MouseButton
    action*: MouseAction
    mods*: set[Modifier]

  WindowSizeMsg* = ref object of Msg
    ## Sent once at startup and again on every SIGWINCH.
    width*, height*: int
    pixelWidth*, pixelHeight*: int
      ## The same window in pixels, or `0` when the terminal did not say — which
      ## is common, and is *unknown* rather than empty. Only useful to something
      ## drawing images, which needs the cell size these divide down to.
      ##
      ## Note that a resize is detected from the cell size alone, so a terminal
      ## that changes its font without changing the grid does not produce a
      ## message even though these two have changed.

  OscMsg* = ref object of Msg
    ## An OSC string the terminal sent us: everything between `ESC ]` and the
    ## terminator, so an OSC 11 reply arrives with `payload` of
    ## `11;rgb:1e1e/1e1e/1e1e`.
    ##
    ## Almost always an answer to a question — either one this program asked (see
    ## `nimtui/query <query.html>`_) or one something else sharing the terminal
    ## did. An application with no interest in them can ignore this type
    ## entirely; the point of decoding it is that the bytes are then *not* typed
    ## into the focused widget as runes, which is what happened before there was
    ## a message for them.
    payload*: string

  PasteMsg* = ref object of Msg
    ## Text the user pasted, delivered whole rather than as a thousand
    ## keystrokes. Sent only when the program was created with
    ## `poBracketedPaste`.
    ##
    ## `text` is verbatim what sat between the two markers. A newline in it is
    ## *data*, not `kEnter`, which is the entire point: pasting two lines into a
    ## text field used to submit the first one halfway through the paste, move
    ## focus, or open whatever was selected.
    ##
    ## Despite arriving from the terminal like `OscMsg`_ above, this is *not* a
    ## runtime bookkeeping message — `program.handle` does not intercept it and
    ## it reaches `update` like any other. Handle it, or with the option on,
    ## pasted text is discarded.
    text*: string

  FocusMsg* = ref object of Msg
    ## The terminal window gained or lost focus. Sent only when the program was
    ## created with `poFocusReporting`.
    ##
    ## What it is for is doing *less*: pausing an animation, stopping a poll, or
    ## dimming the cursor block while nobody is looking. A program that ignores
    ## it is not broken, which is the difference between this and `PasteMsg`_.
    focused*: bool

  TerminalBgMsg* = ref object of Msg
    ## The terminal's background colour, sent once at startup when the program
    ## was created with `poQueryBackground`.
    ##
    ## `ckDefault` means the terminal would not say — no answer, a malformed one,
    ## or not a terminal at all. That is not an error and every recipient has to
    ## handle it: it is the normal case on a terminal that does not implement
    ## OSC 11, and a palette that cannot cope without an answer should not be
    ## asking. Delivered before the first `WindowSizeMsg` and before `initCmd`
    ## runs, so a theme derived from it is in place for the first frame.
    color*: Color

  QuitMsg* = ref object of Msg
    ## Stops the runtime. Not forwarded to `update`.

  BatchMsg* = ref object of Msg
    ## Internal: expands into several commands. Produced by `batch`.
    cmds*: seq[Cmd]

  ScheduleMsg* = ref object of Msg
    ## Internal: asks the runtime to deliver `payload` at `dueAt`.
    ## Produced by `after` / `tick`.
    dueAt*: MonoTime
    payload*: Msg

  ExecResult* = object
    ## How an `execCmd`_ turned out.
    code*: int
      ## The child's exit status, 128 plus the signal that killed it, or `-1`
      ## when it never ran — which `error` then explains.
    error*: ref CatchableError
      ## Set only when the child could not be *started*: a missing binary, a
      ## fork that failed. A child that ran and exited non-zero is not an error
      ## here, because whether it is one is the application's question — `git
      ## commit` exiting 1 means the user changed their mind.

  ExecDone* = proc (r: ExecResult): Msg {.closure.}
    ## What to send once the child is finished. May return `nil`.

  ExecMsg* = ref object of Msg
    ## Internal: hand the terminal to another program, wait for it, and take it
    ## back. Produced by `execCmd`_, intercepted by the runtime, and never
    ## forwarded to `update`.
    command*: string
    args*: seq[string]
    then*: ExecDone

  SuspendMsg* = ref object of Msg
    ## Internal: stop the process the way ctrl+z stops one that is not in raw
    ## mode. Produced by `suspendCmd`_, intercepted by the runtime, and never
    ## forwarded to `update`.

  ErrorMsg* = ref object of Msg
    ## A command raised. The runtime forwards this to `update` rather than
    ## unwinding, so the application decides whether to quit.
    error*: ref CatchableError

  TickMsg* = ref object of Msg
    ## Generic timer payload for applications that need only one timer.
    at*: MonoTime

proc quitCmd*(): Cmd =
  ## Command that stops the program.
  result = proc (): Msg = QuitMsg()

proc execCmd*(command: string, args: openArray[string] = [],
              then: ExecDone = nil): Cmd =
  ## Command that puts the terminal back, runs `command` on it, and takes the
  ## terminal again when it exits — `$EDITOR`, `git`, `less`, anything that wants
  ## the screen to itself.
  ##
  ## ```nim
  ## execCmd(getEnv("EDITOR", "vi"), [path], proc (r: ExecResult): Msg =
  ##   if r.error != nil: ErrorMsg(error: r.error) else: ReloadMsg())
  ## ```
  ##
  ## No new machinery in the loop and no concurrency: the loop is single-threaded
  ## and commands already run synchronously between updates, so a child process
  ## is just a very long command. Nothing is delivered and nothing is drawn until
  ## it exits, which is the correct behaviour rather than a limitation — the
  ## child owns the screen for that whole time.
  ##
  ## `then` is where the answer goes, since a command's own return value has
  ## already been consumed producing this message. If it is `nil` and the child
  ## could not be started, an `ErrorMsg`_ is delivered instead, so a typo in a
  ## binary name is never silent.
  ##
  ## Under `runHeadless` no child is run — there is no terminal to hand over, and
  ## a test suite is not a thing that should be spawning editors. `then` is still
  ## called, with an `error` saying so, so a state machine waiting on it carries
  ## on rather than stalling.
  let a = @args
  result = proc (): Msg = ExecMsg(command: command, args: a, then: then)

proc suspendCmd*(): Cmd =
  ## Command that suspends the program, as ctrl+z does for a program that is not
  ## in raw mode. The terminal is put back first and set up again on resume, and
  ## the program carries on from the next message.
  ##
  ## Explicit rather than automatic, unlike the handler that catches a `SIGTSTP`
  ## arriving from outside. Raw mode clears `ISIG`, so ctrl+z reaches `update` as
  ## an ordinary key — and plenty of programs want it for something else, undo
  ## being the obvious one. Binding it is therefore the application's decision,
  ## the same way `quitCmd`_ is while the terminate handler is not.
  ##
  ## A no-op under `runHeadless`, which has no terminal to put back and no
  ## business stopping the test process that is driving it.
  result = proc (): Msg = SuspendMsg()

proc msgCmd*(m: Msg): Cmd =
  ## Command that immediately re-injects `m`.
  result = proc (): Msg = m

proc batch*(cmds: varargs[Cmd]): Cmd =
  ## Combine commands into one. nil entries are dropped. Order of execution is
  ## the order given, but each command's message is processed as it arrives.
  var kept: seq[Cmd]
  for c in cmds:
    if c != nil: kept.add c
  if kept.len == 0: return nil
  if kept.len == 1: return kept[0]
  result = proc (): Msg = BatchMsg(cmds: kept)

proc after*(d: Duration, m: Msg): Cmd =
  ## Deliver `m` once, `d` from when the command runs.
  result = proc (): Msg = ScheduleMsg(dueAt: getMonoTime() + d, payload: m)

proc tick*(d: Duration): Cmd =
  ## Deliver a `TickMsg` once, `d` from now. Re-issue from `update` to repeat.
  result = proc (): Msg =
    let due = getMonoTime() + d
    ScheduleMsg(dueAt: due, payload: TickMsg(at: due))

proc keyName*(k: Key): string =
  case k
  of kNone: "none"
  of kRune: "rune"
  of kSpace: "space"
  of kEnter: "enter"
  of kTab: "tab"
  of kShiftTab: "shift+tab"
  of kBackspace: "backspace"
  of kEsc: "esc"
  of kUp: "up"
  of kDown: "down"
  of kRight: "right"
  of kLeft: "left"
  of kHome: "home"
  of kEnd: "end"
  of kPgUp: "pgup"
  of kPgDown: "pgdown"
  of kInsert: "insert"
  of kDelete: "delete"
  of kF1 .. kF12: "f" & $(ord(k) - ord(kF1) + 1)

proc `$`*(k: KeyMsg): string =
  ## Human-readable key description, e.g. `ctrl+c`, `alt+up`, `a`.
  if k == nil: return "nil"
  var parts: seq[string]
  if mCtrl in k.mods: parts.add "ctrl"
  if mAlt in k.mods: parts.add "alt"
  if mShift in k.mods and k.key != kShiftTab: parts.add "shift"
  parts.add(if k.key == kRune: $k.rune else: keyName(k.key))
  parts.join("+")

type
  KeySpec = object
    ## What a `KeyMsg` has to hold to match a spec. Built at compile time by
    ## `parseKeySpec` and spliced into the call site by `matches`_, so it never
    ## exists at run time as a value.
    key: Key
    rune: int32
      ## The rune as its codepoint rather than as a `Rune`, and only because
      ## `macros.newLit` cannot build one: `Rune` is `distinct int32`, which
      ## every `newLit` overload declines. Meaningless unless `key` is `kRune`.
    mods: set[Modifier]

const ModifierNames = [("ctrl", mCtrl), ("alt", mAlt), ("shift", mShift)]

proc matchesSpec(k: KeyMsg, key: Key, rune: int32,
                 mods: set[Modifier]): bool {.inline.} =
  ## The whole of the run-time cost of `matches`_: a nil check and three
  ## comparisons against literals, with no allocation anywhere — against the
  ## `seq[string]` and the `join` that `$` builds on every keypress.
  ##
  ## `rune` is consulted only for `kRune`, which is not an optimisation but a
  ## correctness point — `input` reports the space bar as `kSpace` *carrying*
  ## `Rune(' ')`, so a `KeySpec` for `space` (rune 0) would never match one if
  ## the field were compared unconditionally.
  k != nil and k.key == key and k.mods == mods and
    (key != kRune or k.rune.int32 == rune)

proc parseKeySpec(spec: string): tuple[parsed: KeySpec, err: string] =
  ## Turn `"ctrl+alt+delete"` into what a matching `KeyMsg` holds. Returns the
  ## reason instead when there is no such key, which `matches`_ then reports as
  ## a compile error against the offending literal.
  ##
  ## Modifier words are eaten from the front one `word+` at a time and whatever
  ## is left is the key name, taken whole. Splitting on `'+'` instead looks
  ## simpler and cannot express the plus key: `$k` renders that as `"+"` and
  ## ctrl+plus as `"ctrl++"`, both of which this reads correctly because only
  ## the *prefixes* are split off.
  var mods: set[Modifier]
  var i = 0
  while i < spec.len:
    var found = false
    for (word, m) in ModifierNames:
      if spec.len > i + word.len and spec[i + word.len] == '+' and
         spec[i ..< i + word.len] == word:
        if m in mods:
          return (KeySpec(), "modifier '" & word & "' given twice")
        mods.incl m
        i += word.len + 1
        found = true
        break
    if not found: break                         # the rest of it is the key name

  let name = spec[i .. ^1]
  if name.len == 0:
    return (KeySpec(), if i == 0: "empty key spec"
                       else: "ends with a modifier and names no key")

  # The name table is derived from `keyName` rather than written out again, so
  # the two cannot come to disagree and a key added to the enum is bindable by
  # the name it already prints as. `kShiftTab` is in it and unreachable through
  # it — its name contains the `'+'` the loop above has already eaten — which is
  # what the fixup below is for.
  for k in Key:
    if keyName(k) == name:
      if k in {kNone, kRune}:
        return (KeySpec(), "\"" & name & "\" is how `$` prints a key of that " &
                           "kind, not a key: no `KeyMsg` is ever equal to it")
      var key = k
      if k == kTab and mShift in mods: key = kShiftTab
      return (KeySpec(key: key, mods: mods), "")

  if name.runeLen == 1:
    let r = name.runeAt(0).int32
    if r == ' '.int32:
      return (KeySpec(), "the space bar is `kSpace`, not a rune: write \"space\"")
    # The next three are all the legacy encoding folding shift into the
    # character itself, so each names a key no terminal reports and each would
    # sit there never firing. Revisit them with the kitty keyboard protocol,
    # which sends the base key and the modifiers separately and so can produce
    # the first two.
    if mShift in mods and mCtrl in mods:
      return (KeySpec(), "the legacy encoding cannot represent ctrl+shift with " &
                         "a character — it has one control code per letter and " &
                         "no bit left for shift")
    if mShift in mods:
      let hint = if r in 'a'.int32 .. 'z'.int32: " (\"" & $Rune(r - 32) & "\")"
                 else: ""
      return (KeySpec(), "shift is folded into the rune by the legacy " &
                         "encoding: write the shifted character itself" & hint)
    if r in 'A'.int32 .. 'Z'.int32 and mCtrl in mods:
      return (KeySpec(), "a control character decodes to its lower-case " &
                         "letter: write \"ctrl+" & $Rune(r + 32) & "\"")
    return (KeySpec(key: kRune, rune: r, mods: mods), "")

  # A `'+'` still in the name means the word in front of it was meant as a
  # modifier and is not one of the three — `"Ctrl+c"`, `"meta+x"` — which is
  # worth saying, since "no key is named Ctrl+c" describes the symptom rather
  # than the mistake.
  let plus = name.find('+')
  if plus > 0:
    return (KeySpec(), "\"" & name[0 ..< plus] & "\" is not a modifier; the " &
                       "three are ctrl, alt and shift, all lower case")
  (KeySpec(), "no key is named \"" & name & "\"")

macro matches*(k: KeyMsg, specs: varargs[untyped]): bool =
  ## True when `k` is any of the given keys, named exactly as `$` prints
  ## them — `"q"`, `"ctrl+c"`, `"alt+up"`, `"f5"`, `"shift+tab"`.
  ##
  ## ```nim
  ## if k.matches("up", "k", "ctrl+p"): m.cursor.dec
  ## elif k.matches("q", "ctrl+c"): result[1] = quitCmd()
  ## ```
  ##
  ## This is the `case $k` idiom with the two things wrong with it removed. It
  ## allocates nothing, where `$` builds a `seq[string]` and joins it on every
  ## keypress; and **a spec that names no key is a compile error** rather than a
  ## branch that silently never runs. `"pgdn"`, `"escape"` and `"ctrl+W"` are all
  ## rejected with the spelling that was meant — they are wrong in a way no test
  ## catches short of exercising that exact key, which is the whole reason for
  ## reading the string at compile time.
  ##
  ## The specs must be string literals, since a spec that is not there to read
  ## when the program is compiled cannot be checked. There is deliberately no
  ## run-time form: it would be `$k == spec`, which is what this exists to
  ## replace. `$` itself stays for logging and for showing a user what they
  ## pressed.
  ##
  ## Modifiers may be given in any order; `$` prints them ctrl, alt, shift. What
  ## is checked is that the spec names a key that can be *spelled*, not that this
  ## terminal can send it — `"ctrl+esc"` parses and no legacy terminal reports it.
  if specs.len == 0:
    error("matches needs at least one key spec", k)

  # `k` is bound once and shared. It is usually a symbol, but `KeyMsg(msg)` is
  # the other idiomatic spelling and splicing that into every alternative would
  # repeat the conversion per spec.
  let key = genSym(nskLet, "key")
  var test: NimNode
  for s in specs:
    if s.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error("matches takes string literals, so that a key spec that names " &
            "nothing is caught here rather than never firing", s)
    let (parsed, err) = parseKeySpec(s.strVal)
    if err.len > 0:
      error("bad key spec \"" & s.strVal & "\": " & err, s)
    let one = newCall(bindSym"matchesSpec", (if specs.len == 1: k else: key),
                      newLit(parsed.key), newLit(parsed.rune),
                      newLit(parsed.mods))
    test = if test == nil: one else: infix(test, "or", one)

  result = if specs.len == 1: test
           else: newStmtList(newLetStmt(key, k), test).newBlockStmt
