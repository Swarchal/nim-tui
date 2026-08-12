import std/[unittest, unicode]
import nimtui/messages

## `matches` is `case $k` with the two faults taken out of it, so what has to be
## pinned is that it agrees with `$` on every key and that it *stops compiling*
## on the specs that used to be silent no-ops. The second half is the point of
## the feature and is the half no ordinary test can reach: a misspelled binding
## is invisible until someone presses that exact key.

proc key(k: Key, r = "", mods: set[Modifier] = {}): KeyMsg =
  KeyMsg(key: k, rune: (if r.len > 0: r.runeAt(0) else: Rune(0)), mods: mods)

const ModSets: array[8, set[Modifier]] = [
  {}, {mCtrl}, {mAlt}, {mShift},
  {mCtrl, mAlt}, {mCtrl, mShift}, {mAlt, mShift}, {mCtrl, mAlt, mShift}]

proc corpus(): seq[KeyMsg] =
  ## Every key `input` can report, over every combination of modifiers, plus a
  ## spread of runes chosen for the edges: the two cases of a letter, the `'+'`
  ## the spec grammar has to survive, a digit and a wide rune.
  for k in Key:
    if k == kNone: continue                     # never delivered; `parseInput` returns nil instead
    for mods in ModSets:
      # `$` is not injective around shift+tab: `kShiftTab` prints the same with
      # and without `mShift`, and `kTab` carrying `mShift` prints as it too. Of
      # those three only `kShiftTab` with the modifier is ever delivered, and the
      # agreement below can only hold on what the decoder actually produces.
      if k == kShiftTab and mShift notin mods: continue
      if k == kTab and mShift in mods: continue
      if k == kRune:
        for r in ["a", "A", "z", "+", "1", "あ"]:
          result.add key(kRune, r, mods)
      else:
        # The space bar arrives as `kSpace` *carrying* `Rune(' ')`, which is the
        # reason the rune is compared only for `kRune`.
        result.add key(k, (if k == kSpace and mods == {}: " " else: ""), mods)

let Keys = corpus()

template agrees(spec: static string) =
  ## The property every case below is an instance of: over the whole corpus,
  ## `matches` and `$` say the same thing. That catches a spec matching the
  ## *wrong* key as well as one failing to match the right one, and it is what
  ## keeps the two spellings of a key name from drifting apart.
  for k in Keys:
    checkpoint spec & " vs " & $k
    check k.matches(spec) == ($k == spec)

suite "key matching agrees with `$`":
  test "runes":
    agrees("a")
    agrees("A")
    agrees("z")
    agrees("1")
    agrees("+")
    agrees("あ")

  test "named keys":
    agrees("space")
    agrees("enter")
    agrees("tab")
    agrees("shift+tab")
    agrees("backspace")
    agrees("esc")
    agrees("up")
    agrees("down")
    agrees("left")
    agrees("right")
    agrees("home")
    agrees("end")
    agrees("pgup")
    agrees("pgdown")
    agrees("insert")
    agrees("delete")
    agrees("f1")
    agrees("f5")
    agrees("f10")
    agrees("f12")

  test "modified keys":
    agrees("ctrl+c")
    agrees("ctrl+space")
    agrees("ctrl++")
    agrees("alt+up")
    agrees("alt+a")
    agrees("shift+up")
    agrees("ctrl+alt+delete")
    agrees("ctrl+shift+home")
    agrees("ctrl+alt+shift+f4")

suite "key matching":
  test "a nil key matches nothing":
    # `$` guards for nil and so must this: a `KeyMsg` field left unset is the
    # ordinary way to spell "no key yet" in a model.
    let k = KeyMsg(nil)
    check not k.matches("q")
    check not k.matches("q", "ctrl+c", "up")

  test "several specs are an or":
    let k = key(kRune, "p", {mCtrl})
    check k.matches("up", "k", "ctrl+p")
    check k.matches("ctrl+p", "up")
    check not k.matches("up", "k", "ctrl+n")

  test "the key is evaluated once however many specs there are":
    # `KeyMsg(msg)` is the other idiomatic spelling of the argument, so the
    # alternatives share one binding rather than repeating the conversion.
    var calls = 0
    proc probe(k: KeyMsg): KeyMsg =
      inc calls
      k
    let k = key(kUp)
    check probe(k).matches("down", "left", "up")
    check calls == 1

  test "modifiers may be given in any order":
    let k = key(kUp, "", {mCtrl, mAlt})
    check k.matches("ctrl+alt+up")
    check k.matches("alt+ctrl+up")

  test "the rune is compared only for kRune":
    # The space bar carries `Rune(' ')` and ctrl+space does not, and both are
    # `kSpace`. Comparing the field unconditionally would match one and not the
    # other while `$` calls them both "space".
    check key(kSpace, " ").matches("space")
    check key(kSpace).matches("space")
    check key(kSpace, "", {mCtrl}).matches("ctrl+space")

  test "shift+tab is its own key, not tab with a modifier":
    check key(kShiftTab, "", {mShift}).matches("shift+tab")
    check not key(kTab, "", {mShift}).matches("shift+tab")
    check not key(kShiftTab, "", {mShift}).matches("tab")

suite "key specs that name nothing are compile errors":
  ## The whole reason for reading the string at compile time. Each of these used
  ## to compile into a branch that could never be taken, which no test catches
  ## short of exercising that exact key.
  setup:
    let k = key(kRune, "q")

  test "a spec that does match still compiles":
    check compiles(k.matches("q"))
    check compiles(k.matches("ctrl+c"))
    check compiles(k.matches("shift+tab"))
    check compiles(k.matches("f12"))
    check compiles(k.matches("+"))
    check compiles(k.matches("ctrl++"))
    check compiles(k.matches("q", "ctrl+c"))

  test "a misspelled key name":
    check not compiles(k.matches("pgdn"))
    check not compiles(k.matches("escape"))
    check not compiles(k.matches("pageup"))
    check not compiles(k.matches("del"))
    check not compiles(k.matches("f13"))

  test "a misspelled modifier":
    check not compiles(k.matches("Ctrl+c"))
    check not compiles(k.matches("meta+x"))
    check not compiles(k.matches("cmd+q"))

  test "a bad spec anywhere in the list":
    # The alternatives are where a typo hides best: the branch still fires for
    # the other keys, so it looks like it works.
    check not compiles(k.matches("up", "pgdn"))
    check not compiles(k.matches("pgdn", "up"))

  test "shift folded into a character, which is how the legacy encoding sends it":
    check not compiles(k.matches("ctrl+W"))
    check not compiles(k.matches("shift+a"))
    check not compiles(k.matches("ctrl+shift+w"))

  test "a modifier with no key, and other empty parts":
    check not compiles(k.matches("ctrl+"))
    check not compiles(k.matches(""))
    check not compiles(k.matches("ctrl+ctrl+a"))

  test "the names `$` prints for a kind rather than a key":
    check not compiles(k.matches("none"))
    check not compiles(k.matches("rune"))

  test "the space bar is spelled, not typed":
    check not compiles(k.matches(" "))

  test "a spec that is not a literal":
    # Deliberate: a spec that is not there to read when the program is compiled
    # cannot be checked, and an unchecked spec is what this replaces.
    var spec = "q"
    check not compiles(k.matches(spec))
    check not compiles(k.matches(["q", "up"]))
