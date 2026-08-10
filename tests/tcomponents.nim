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

  test "every way in flattens, not just the bulk one":
    # The bulk insert was flattened when it was added and the other two entry
    # points were not, which left the rule true of the path that had the least
    # need of it. `input`'s generic UTF-8 fallback decodes any well-formed
    # sequence to a `kRune` without asking what it is, so a C1 control reaches
    # the single-rune path; `text=` takes a string straight from outside.
    var ti = initTextInput()
    ti.insert Rune(0x0085)                  # NEL, a C1 control
    ti.insert Rune('a')
    check ti.text == " a"

    ti = initTextInput()
    ti.text = "a\nb\e c"
    check "\e" notin ti.text
    check "\n" notin ti.text
    check ti.text == "a b  c"          # the ESC became one space, beside the real one
    check ti.cursor == ti.runes.len

  test "a flattened rune is measured as the space it is drawn as":
    # The failure this prevents is invisible to a width assertion made in terms
    # of `runes`: a control is zero columns to `runeWidth` and an action to the
    # terminal, so the field measures itself consistently and still draws wrong.
    var ti = initTextInput()
    ti.insert Rune(0x0085)
    for w in [4, 10, 20]:
      check displayWidth(ti.render(w)) == w

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

suite "scrollbar in eighths":
  ## The dimensional assertion first, since a gutter one column wider than it
  ## claims wraps the row it is appended to, and the rest of the frame with it.

  test "every cell is exactly one column, at every position and every scale":
    for total in [11, 12, 25, 40, 200, 5000]:
      for top in 0 .. total - 10:
        for cell in Viewport(top: top, height: 10).smoothScrollbar(total):
          checkpoint "total " & $total & " top " & $top & " cell " & escape(cell)
          check displayWidth(cell) == 1

  test "one cell per visible row, and none at all for no rows":
    check Viewport(top: 0, height: 10).smoothScrollbar(100).len == 10
    check Viewport(top: 0, height: 0).smoothScrollbar(100).len == 0

  test "everything fitting is all track and no thumb":
    let bar = Viewport(top: 0, height: 10).smoothScrollbar(10, Style())
    check bar == newSeqWith(10, " ")

  test "the ends are flush, which is what says there is no more to scroll":
    # The two positions a reader checks against the content rather than against
    # the thumb, so an off-by-an-eighth here reads as "there is a little more".
    let atTop = Viewport(top: 0, height: 10).smoothScrollbar(25, Style())
    let atBottom = Viewport(top: 15, height: 10).smoothScrollbar(25, Style())
    check atTop[0] == "█"
    check atTop[^1] == " "
    check atBottom[^1] == "█"
    check atBottom[0] == " "

  test "the thumb moves in eighths where the whole-cell one does not move":
    # The point of the exercise. Ten rows over a thousand lines: the whole-cell
    # thumb has one picture for the first ninety positions and this has several,
    # which is the difference between a scrollbar that responds to a keypress and
    # one that appears stuck.
    proc pictures(smooth: bool): int =
      var seen: seq[string]
      for top in 0 .. 90:
        let v = Viewport(top: top, height: 10)
        let s = (if smooth: v.smoothScrollbar(1000, Style())
                 else: v.scrollbar(1000)).join("")
        if s notin seen: seen.add s
      seen.len
    check pictures(smooth = false) == 1
    check pictures(smooth = true) > 5

  test "the lower end is reversed, since Unicode has no top-filled blocks":
    # Not a style preference: `▁`..`▇` fill from the bottom and there is no
    # matching set filled from the top, so the bottom of the thumb can only be
    # drawn by swapping foreground and background. Dropping the reverse leaves a
    # thumb with a gap under it and a stripe below the gap.
    let bar = Viewport(top: 1, height: 10).smoothScrollbar(25, Style())
    let ends = bar.filterIt(Style().reverse().sgr() in it)
    check ends.len == 1

  test "a partial cell keeps the track's background under the thumb's colour":
    let bar = Viewport(top: 1, height: 10).smoothScrollbar(
      25, Style().fg(hex"#ff0000"), Style().bg(hex"#0000ff"))
    let partial = bar.filterIt("▅" in it or "▂" in it)
    check partial.len > 0
    for cell in partial:
      # The parameters rather than the whole escape: `sgr` coalesces a
      # foreground and a background into one sequence, so the two colours are in
      # there together or not at all.
      checkpoint escape(cell)
      check "38;2;255;0;0" in cell
      check "48;2;0;0;255" in cell

  test "withScrollbar is smooth by default and can be asked not to be":
    let v = Viewport(top: 0, height: 3)
    let smooth = v.withScrollbar(@["a", "b", "c"], 30)
    let whole = v.withScrollbar(@["a", "b", "c"], 30, smooth = false)
    check "█" in smooth[0]
    check "┃" in whole[0]
    # Whichever it is, the row grew by exactly one column.
    for row in smooth & whole:
      check displayWidth(row) == 2

suite "term size":
  ## The bool is the `handleKey` contract applied to a resize, and the value of
  ## the whole thing is that it means the same as everywhere else in the library.

  test "a window size message is stored and claimed":
    var s = TermSize()
    check s.handleResize(WindowSizeMsg(width: 120, height: 40))
    check s.width == 120
    check s.height == 40

  test "anything else is left alone, and said not to be ours":
    var s = TermSize(width: 80, height: 24)
    check not s.handleResize(KeyMsg(key: kEnter))
    check not s.handleResize(PasteMsg(text: "hello"))
    check not s.handleResize(Msg())
    check s == TermSize(width: 80, height: 24)   # untouched by all three

  test "a later message replaces the size rather than merging into it":
    var s = TermSize()
    discard s.handleResize(WindowSizeMsg(width: 120, height: 40))
    discard s.handleResize(WindowSizeMsg(width: 80, height: 24))
    check s == TermSize(width: 80, height: 24)

  test "true means the message was ours, not that the size changed":
    # The two coincide on the real loop, since `syncSize` drops a resize that
    # reports the size it last reported — but they are different questions and
    # only one of them is the library-wide meaning of this bool.
    var s = TermSize(width: 80, height: 24)
    check s.handleResize(WindowSizeMsg(width: 80, height: 24))

  test "it is zero until something says otherwise":
    # Not a guessed 80x24: before the terminal has answered, the honest value is
    # unknown, and a view that divides by a dimension has to clamp either way.
    var s = TermSize()
    check s.width == 0
    check s.height == 0

  test "pixels are not folded in":
    # A resize is detected from the cell size alone and most terminals report no
    # pixels at all, so a program that wants them wants the message.
    var s = TermSize()
    check s.handleResize(WindowSizeMsg(width: 100, height: 30,
                                       pixelWidth: 800, pixelHeight: 600))
    check s == TermSize(width: 100, height: 30)
