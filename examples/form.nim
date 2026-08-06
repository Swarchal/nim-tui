## A form: several text fields, focus moving between them, live validation.
##
## What this example is really about: dispatching keys when more than one
## component could want them. There is exactly one rule, and it scales to any
## number of components — **offer the key to the focused one first, and treat
## whatever it declines as navigation**:
##
## ```nim
## if m.fields[m.focus].input.handleKey(k): return   # it was text
## case $k                                           # it was a command
## of "tab": ...
## ```
##
## Also shows `TextInput`'s `mask`, on the password field: it changes what
## `render` draws and nothing else, so validation, the cursor and the horizontal
## scroll all still work on the real text.
##
## That works because `TextInput.handleKey` returns false for anything that is
## not editing. `left` and `home` are the field's; `tab`, `up` and `enter` fall
## through and become focus movement. No mode flag, no list of keys to exclude,
## and adding a field changes nothing — which is the point, because the
## alternative (an `if` over modes that has to know which keys the field wants)
## goes wrong the first time someone adds a binding.
##
##   nim c -r --path:src examples/form.nim

import std/[math, strutils, strformat, unicode]
import nimtui

type
  FieldKind = enum
    fkText, fkEmail, fkHost, fkPort, fkSecret

  Field = object
    label, hint: string
    kind: FieldKind
    required: bool
    input: TextInput
    error: string

  Model = object
    fields: seq[Field]
    focus: int
    submitted: bool
    width, height: int
    theme: Theme

const FormWidth = 54

# --- validation ---------------------------------------------------------------

proc validate(f: Field): string =
  ## The error message for a field, or "" when it is fine.
  let v = f.input.text.strip
  if v.len == 0:
    return if f.required: "required" else: ""
  case f.kind
  of fkText:
    if v.len < 2: "must be at least 2 characters" else: ""
  of fkEmail:
    let at = v.find('@')
    if at <= 0: "needs a name before the @"
    elif v.find('.', at) < 0: "needs a domain after the @"
    else: ""
  of fkHost:
    if ' ' in v: "cannot contain spaces" else: ""
  of fkPort:
    try:
      let n = parseInt(v)
      if n < 1 or n > 65535: "must be between 1 and 65535" else: ""
    except ValueError:
      "must be a number"
  of fkSecret:
    # Validated on what was typed, not on what is drawn: the mask is a render
    # concern and `text` still returns the real thing.
    if v.len < 8: "must be at least 8 characters" else: ""

proc revalidate(m: var Model) =
  for f in m.fields.mitems:
    f.error = f.validate

proc valid(m: Model): bool =
  for f in m.fields:
    if f.error.len > 0: return false
  true

# --- update -------------------------------------------------------------------

proc moveFocus(m: var Model, delta: int) =
  m.focus = floorMod(m.focus + delta, m.fields.len)

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of WindowSizeMsg:
    result[0].width = WindowSizeMsg(msg).width
    result[0].height = WindowSizeMsg(msg).height

  elif msg of KeyMsg:
    let k = KeyMsg(msg)

    if m.submitted:
      # The confirmation is modal, so it swallows everything.
      if $k in ["q", "ctrl+c"]: result[1] = quitCmd()
      else: result[0].submitted = false
      return

    # The focused field gets first refusal. Everything it declines is a command
    # — this single line is what the whole example is about.
    if result[0].fields[result[0].focus].input.handleKey(k):
      result[0].revalidate()
      return

    case $k
    of "ctrl+c": result[1] = quitCmd()
    of "esc": result[1] = quitCmd()
    of "tab", "down", "ctrl+n": result[0].moveFocus 1
    of "shift+tab", "up", "ctrl+p": result[0].moveFocus(-1)
    of "enter":
      result[0].revalidate()
      if result[0].focus == m.fields.high:
        # Submitting an invalid form moves to the first offending field rather
        # than just refusing: an error message the user cannot see is no better
        # than no message.
        if result[0].valid: result[0].submitted = true
        else:
          for i, f in result[0].fields:
            if f.error.len > 0:
              result[0].focus = i
              break
      else: result[0].moveFocus 1
    else: discard

# --- view ---------------------------------------------------------------------

proc renderField(m: Model, i, width: int): string =
  let
    f = m.fields[i]
    t = m.theme
    focused = i == m.focus
    bad = f.error.len > 0

  # The border does the work of showing focus and validity at once: heavy and
  # accented when focused, red when the value is wrong, quiet otherwise.
  let borderColour =
    if bad: t.error
    elif focused: t.borderActive
    else: t.border

  let box = panel(if focused: ThickBorder else: RoundedBorder)
    .title(" " & f.label & (if f.required: " *" else: "") & " ")
    .styled(border = Style().fg(borderColour),
            title = if focused: t.titleStyle else: t.mutedStyle)
    .render(" " & f.input.render(max(width - 4, 1), focused) & " ", width, 3)

  let note =
    if bad: t.errorStyle.render("▲ " & f.error)
    elif focused: t.mutedStyle.render(f.hint)
    else: ""
  joinVertical(box, "  " & padVisible(note, max(width - 2, 1)))

proc summary(m: Model): string =
  let t = m.theme
  var rows = @[""]
  for f in m.fields:
    rows.add span(padVisible(f.label, 10), t.mutedStyle).render() &
             t.successStyle.render(f.input.text)
  rows.add ""
  rows.add t.mutedStyle.render("any key to go back · q to quit")
  panel(DoubleBorder)
    .title(" submitted ", aCenter)
    .pad(2)
    .shadow(t.mutedStyle)
    .styled(border = t.successStyle, title = t.successStyle)
    .render(rows.join("\n"), 44, rows.len + 5)

proc view(m: Model): string =
  if m.width == 0: return "loading…"
  let
    t = m.theme
    w = m.width
    formW = min(max(w - 4, 20), FormWidth)

  var parts: seq[string]
  parts.add gradientText("  new connection", t.ramp, Style().bold())
  parts.add ""
  for i in 0 ..< m.fields.len:
    parts.add m.renderField(i, formW)
  parts.add ""

  let allGood = m.valid
  parts.add "  " & (if allGood: t.successStyle.render("✓ ready — enter to submit")
                    else: t.mutedStyle.render("fill the fields marked *"))

  let form = parts.join("\n")
  # A blank canvas the size of the screen, with the form placed on it — which is
  # how `place` is meant to be used: the base fixes the dimensions, so nothing
  # inside can change the frame's size.
  let body = place(padBlock("", w, max(m.height - 1, 1)), form)
  let footer = statusBar(
    # Kept short deliberately: `statusBar` drops the centre and then eats into
    # the right segment when the three cannot fit, so an over-long hint list
    # silently truncates the field counter rather than wrapping.
    " " & hints({"tab": "next", "enter": "submit", "esc": "quit"}), "",
    t.mutedStyle.render(&"field {m.focus + 1}/{m.fields.len} "), w)

  let frame = joinVertical(body, footer)
  if m.submitted: place(frame, m.summary) else: frame

when isMainModule:
  var model = Model(theme: DefaultTheme)
  model.fields = @[
    Field(label: "name", kind: fkText, required: true,
          hint: "how the connection is listed",
          input: initTextInput("production db")),
    Field(label: "email", kind: fkEmail, required: true,
          hint: "who to notify when it fails",
          input: initTextInput("you@example.com")),
    Field(label: "host", kind: fkHost, required: true,
          hint: "hostname or address",
          input: initTextInput("db.internal")),
    Field(label: "port", kind: fkPort, required: true,
          hint: "1-65535",
          input: initTextInput("5432")),
    Field(label: "password", kind: fkSecret, required: true,
          hint: "drawn masked, validated on what was typed",
          input: initTextInput("at least 8 characters", mask = Rune('*'))),
  ]
  model.revalidate()
  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor}).run()
