import std/[unittest, unicode, sequtils, strutils]
import nimtui
import nimtui/[textinput, viewport]

## The stateful components: `TextInput` and `Viewport`, which were staged under
## examples/lib until the component API settled, and are now library modules.
## `TextArea` and `ListView` are built on `Viewport` and tested in
## tests/ttextarea and tests/tlistview.

proc press(ti: var TextInput, keys: varargs[string]) =
  for k in keys:
    let msg =
      case k
      of "left": KeyMsg(key: kLeft)
      of "right": KeyMsg(key: kRight)
      of "home": KeyMsg(key: kHome)
      of "end": KeyMsg(key: kEnd)
      of "backspace": KeyMsg(key: kBackspace)
      of "delete": KeyMsg(key: kDelete)
      of "space": KeyMsg(key: kSpace)
      of "ctrl+w": KeyMsg(key: kRune, rune: Rune('w'), mods: {mCtrl})
      of "ctrl+u": KeyMsg(key: kRune, rune: Rune('u'), mods: {mCtrl})
      of "ctrl+k": KeyMsg(key: kRune, rune: Rune('k'), mods: {mCtrl})
      of "alt+left": KeyMsg(key: kLeft, mods: {mAlt})
      of "alt+right": KeyMsg(key: kRight, mods: {mAlt})
      else: KeyMsg(key: kRune, rune: k.runeAt(0))
    discard ti.handleKey(msg)

suite "text input editing":
  test "typing and backspace":
    var ti = initTextInput()
    ti.press "a", "b", "c"
    check ti.text == "abc"
    ti.press "backspace"
    check ti.text == "ab"
    check ti.cursor == 2

  test "the cursor counts runes, not bytes":
    var ti = initTextInput()
    ti.press "é", "é"
    check ti.text == "éé"
    check ti.text.len == 4          # bytes
    check ti.cursor == 2            # runes
    ti.press "backspace"
    check ti.text == "é"            # not a half-rune

  test "inserting mid-string":
    var ti = initTextInput()
    ti.text = "ac"
    ti.press "left", "b"
    check ti.text == "abc"
    check ti.cursor == 2

  test "delete removes forwards, backspace backwards":
    var ti = initTextInput()
    ti.text = "abc"
    ti.press "home", "delete"
    check ti.text == "bc"
    ti.press "end", "backspace"
    check ti.text == "b"

  test "cursor cannot leave the string":
    var ti = initTextInput()
    ti.text = "ab"
    ti.press "left", "left", "left", "left"
    check ti.cursor == 0
    ti.press "backspace"
    check ti.text == "ab"
    ti.press "right", "right", "right"
    check ti.cursor == 2
    ti.press "delete"
    check ti.text == "ab"

  test "ctrl+w deletes the word before the cursor":
    var ti = initTextInput()
    ti.text = "one two three"
    ti.press "ctrl+w"
    check ti.text == "one two "
    ti.press "ctrl+w"
    check ti.text == "one "

  test "ctrl+u and ctrl+k cut to the ends":
    var ti = initTextInput()
    ti.text = "abcdef"
    ti.press "left", "left", "ctrl+u"
    check ti.text == "ef"
    check ti.cursor == 0
    ti.text = "abcdef"
    ti.press "home", "right", "ctrl+k"
    check ti.text == "a"

  test "word motion skips over whitespace":
    var ti = initTextInput()
    ti.text = "one two"
    ti.press "alt+left"
    check ti.cursor == 4
    ti.press "alt+left"
    check ti.cursor == 0
    ti.press "alt+right"
    check ti.cursor == 3

  test "control keys are not typed as text":
    var ti = initTextInput()
    var consumed = ti.handleKey(KeyMsg(key: kRune, rune: Rune('x'),
                                       mods: {mCtrl}))
    check not consumed
    check ti.text == ""
    consumed = ti.handleKey(KeyMsg(key: kEnter))
    check not consumed          # enter belongs to the caller

  test "space is text":
    var ti = initTextInput()
    ti.press "a", "space", "b"
    check ti.text == "a b"

  test "a bulk insert lands at the cursor":
    var ti = initTextInput()
    ti.text = "ad"
    ti.cursor = 1
    ti.insert "bc"
    check ti.text == "abcd"
    check ti.cursor == 3

  test "a bulk insert at either end works too":
    var ti = initTextInput()
    ti.insert "world"
    check ti.text == "world"
    ti.cursor = 0
    ti.insert "hello "
    check ti.text == "hello world"
    check ti.cursor == 6

  test "a bulk insert of multi-byte runes counts characters, not bytes":
    var ti = initTextInput()
    ti.insert "日本語"
    check ti.runes.len == 3
    check ti.cursor == 3
    check ti.text == "日本語"

  test "control characters in pasted text become spaces":
    # An ESC left in `runes` measures a column and draws nothing, so the field
    # would render narrow. A space rather than nothing so words do not run
    # together across a dropped newline.
    var ti = initTextInput()
    ti.insert "a\nb\e[Ac"
    check "\e" notin ti.text
    check "\n" notin ti.text
    check ti.text == "a b [Ac"

  test "an empty bulk insert changes nothing":
    var ti = initTextInput()
    ti.text = "abc"
    ti.cursor = 1
    ti.insert ""
    check ti.text == "abc"
    check ti.cursor == 1

  test "handle takes a paste, a key, and nothing else":
    var ti = initTextInput()
    check ti.handle(PasteMsg(text: "pasted"))
    check ti.text == "pasted"
    check ti.handle(KeyMsg(key: kRune, rune: Rune('!')))
    check ti.text == "pasted!"
    check not ti.handle(KeyMsg(key: kEnter))          # still the caller's
    check not ti.handle(WindowSizeMsg(width: 80, height: 24))

suite "text input rendering":
  test "render is pure and fits the width exactly":
    let ti = block:
      var t = initTextInput()
      t.text = "hello world"
      t
    for w in 1 .. 20:
      check displayWidth(ti.render(w)) == w

  test "scrolls to keep the cursor visible":
    var ti = initTextInput()
    ti.text = "abcdefghij"          # cursor at the end
    check stripAnsi(ti.render(4)).strip == "hij"
    ti.press "home"
    check stripAnsi(ti.render(4)).strip == "abcd"

  test "unfocused and empty shows the placeholder":
    let ti = initTextInput("type here")
    check stripAnsi(ti.render(20, focused = false)).strip == "type here"

  test "double-width text never overflows the field":
    # A rune-counted window would render twice as wide as asked and push the
    # surrounding border off the line.
    var ti = initTextInput()
    ti.text = "日本語のテキスト"
    for w in 1 .. 24:
      check displayWidth(ti.render(w)) == w
    ti.press "home"
    for w in 1 .. 24:
      check displayWidth(ti.render(w)) == w

  test "scrolling keeps a wide cursor rune visible":
    var ti = initTextInput()
    ti.text = "日本語"                    # cursor past the end
    ti.press "left"                       # now on 語
    check stripAnsi(ti.render(4)).strip == "本語"

suite "text input masking":
  test "a masked field shows the mask and still holds the text":
    var ti = initTextInput(mask = Rune('*'))
    ti.text = "hunter2"
    check ti.text == "hunter2"
    check ti.render(20, focused = false).stripAnsi.strip(leading = false) ==
      "*******"

  test "an unmasked field is unchanged, so the mask is genuinely off by default":
    var a = initTextInput()
    a.text = "hunter2"
    var b = initTextInput(mask = Rune(0))
    b.text = "hunter2"
    check a.render(20) == b.render(20)
    check "hunter2" in a.render(20).stripAnsi

  test "the mask is measured as well as drawn":
    # The trap: taking the width from the real rune and drawing the mask sizes
    # the window for text that is not on screen, and a field narrower than it
    # claims desynchronises the frame rather than just looking wrong.
    for w in 1 .. 24:
      checkpoint $w
      var ti = initTextInput(mask = Rune('*'))
      ti.text = "日本語のパスワード"
      check displayWidth(ti.render(w)) == w
      var wide = initTextInput(mask = "＊".runeAt(0))   # fullwidth: two columns
      wide.text = "abcdefghij"
      check displayWidth(wide.render(w)) == w

  test "a wide mask shows fewer characters, which is the honest answer":
    # Fullwidth, so genuinely two columns. Note `●` is *not* a wide rune here:
    # it is East Asian Ambiguous, which this library deliberately calls one.
    var ti = initTextInput(mask = "＊".runeAt(0))
    ti.text = "abcdef"
    check displayWidth(ti.render(10)) == 10
    # Four, not five: one column stays reserved for the cursor block, the same
    # as it is for an unmasked field.
    check ti.render(10, focused = false).stripAnsi.strip(leading = false) ==
      "＊＊＊＊"
    # The same field with a one-column mask shows all six.
    var narrow = initTextInput(mask = Rune('*'))
    narrow.text = "abcdef"
    check narrow.render(10, focused = false).stripAnsi.strip(leading = false) ==
      "******"

  test "the cursor still tracks, and the field still fits":
    var ti = initTextInput(mask = Rune('*'))
    ti.text = "a-very-long-password-indeed"
    for c in [0, 5, 13, ti.runes.len]:
      ti.cursor = c
      checkpoint $c
      check displayWidth(ti.render(12)) == 12

  test "the placeholder is not masked, since it is not the secret":
    var ti = initTextInput("password", mask = Rune('*'))
    check "password" in ti.render(20, focused = false).stripAnsi

suite "viewport":
  test "ensureVisible scrolls the minimum amount":
    var v = Viewport(height: 5)
    v.ensureVisible(7, 20)
    check v.top == 3                      # 7 is now the last visible row
    v.ensureVisible(2, 20)
    check v.top == 2                      # scrolled up just enough

  test "the window never runs past the end":
    var v = Viewport(height: 5)
    v.scrollBy(100, 8)
    check v.top == 3
    check v.atBottom(8)
    v.scrollBy(-100, 8)
    check v.top == 0
    check v.atTop

  test "a list shorter than the window does not scroll":
    var v = Viewport(height: 10)
    v.ensureVisible(2, 3)
    check v.top == 0

  test "window returns only existing items":
    let v = Viewport(top: 6, height: 5)
    check v.window(@[1, 2, 3, 4, 5, 6, 7, 8]) == @[7, 8]

  test "scrollbar is one glyph per row and sized to the window":
    let v = Viewport(top: 0, height: 10)
    check v.scrollbar(100).len == 10
    check v.scrollbar(100).countIt(it == "┃") == 1   # 10/100 of ten rows
    check v.scrollbar(10).countIt(it == "┃") == 0    # everything fits

  test "the scrollbar thumb tracks the offset":
    let top = Viewport(top: 0, height: 10).scrollbar(40)
    let bottom = Viewport(top: 30, height: 10).scrollbar(40)
    check top[0] == "┃"
    check bottom[^1] == "┃"
