## The message and command vocabulary shared by every layer.
##
## `Msg` is an open ref hierarchy: the runtime defines the messages it produces
## (keys, mouse, resize) and applications add their own by inheriting from
## `Msg`. Update procs discriminate with `msg of MyMsg`.
##
## A `Cmd` is a deferred side effect. The runtime runs it and feeds whatever
## `Msg` it returns back through `update`, which is how effects re-enter the
## pure part of the program. Returning `nil` means "no follow-up message".

import std/[monotimes, times, unicode, strutils]
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
