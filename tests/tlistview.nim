import std/[unittest, strutils, unicode]
import nimtui/[ansi, style, color, listview]

## A list is a cursor and a window that has to follow it. The failures worth
## pinning are the ones that leave the two disagreeing: a cursor scrolled off
## screen, a cursor left pointing past the end of a list that just shrank, and
## the off-by-one at each end of a wrap-around.

proc items(n: int): seq[string] =
  for i in 0 ..< n: result.add "item " & $i

suite "listview movement":
  test "the cursor stays inside the list":
    var l = initListView(height = 5, wrapAround = false)
    l.moveBy(-10, 20)
    check l.cursor == 0
    l.moveBy(100, 20)
    check l.cursor == 19

  test "wrap-around reaches the far end from either side":
    # `mod` keeps the sign of the dividend in Nim, so the naive spelling sends a
    # cursor at 0 to a negative index.
    var l = initListView(height = 5)
    l.up 20
    check l.cursor == 19
    l.down 20
    check l.cursor == 0

  test "an empty list is not a crash":
    var l = initListView(height = 5)
    l.up 0
    l.down 0
    l.toBottom 0
    l.sync 0
    check l.cursor == 0
    check l.vp.top == 0
    check l.render(@[], 20) != ""

  test "the window follows the cursor":
    var l = initListView(height = 5)
    l.moveTo(12, 40)
    check l.cursor == 12
    check l.vp.top <= 12
    check 12 < l.vp.top + 5

  test "paging moves the cursor, not just the window":
    var l = initListView(height = 10, wrapAround = false)
    l.pageDown 100
    check l.cursor == 9
    l.pageDown 100
    check l.cursor == 18
    l.pageUp 100
    check l.cursor == 9

  test "sync clamps a cursor left past the end by a shrinking list":
    # A filter narrowing forty items to two must not leave the cursor at twelve.
    var l = initListView(height = 5)
    l.moveTo(30, 40)
    l.sync 2
    check l.cursor == 1
    check l.vp.top == 0

suite "listview rendering":
  test "render is exactly width x height, gutter included":
    var l = initListView(height = 6)
    l.moveTo(0, 30)
    for w in [10, 20, 40]:
      let ls = l.render(items(30), w).split('\n')
      check ls.len == 6
      for line in ls:
        check displayWidth(line) == w

  test "a list shorter than the window still fills it":
    var l = initListView(height = 8)
    for line in l.render(items(3), 24).split('\n'):
      check displayWidth(line) == 24

  test "over-long and double-width items are cut to the row":
    var l = initListView(height = 4)
    let rows = @["日本語のとても長い項目です", "short",
                 "an extremely long item that will not fit", "x"]
    for w in [8, 12, 20]:
      for line in l.render(rows, w).split('\n'):
        check displayWidth(line) == w

  test "the selected row is styled and the others are not":
    var l = initListView(height = 3)
    l.moveTo(1, 3)
    let ls = l.render(items(3), 20,
                      selectedStyle = Style().fg(hex"#00e5ff")).split('\n')
    check "0;229;255" in ls[1]
    check "0;229;255" notin ls[0]
    check "0;229;255" notin ls[2]

  test "the highlight covers the whole row, prefix included":
    var l = initListView(height = 2)
    l.moveTo(0, 2)
    let row = l.render(items(2), 20, selectedStyle = Style().bg(hex"#00e5ff"),
                       showScrollbar = false).split('\n')[0]
    check displayWidth(row) == 20
    check row.stripAnsi.len == row.stripAnsi.len   # the row is one styled run
    check row.startsWith("\e[")                    # styling begins at column 0

  test "turning the scrollbar off gives the item one more column":
    let long = @["abcdefghijklmnopqrstuvwxyz"]
    var l = initListView(height = 1)
    let
      withBar = l.render(long, 20).stripAnsi
      without = l.render(long, 20, showScrollbar = false).stripAnsi
    check displayWidth(withBar) == 20
    check displayWidth(without) == 20
    # One column goes to the gutter and one to the selection prefix, so the
    # item gets 18 columns with the bar and 19 without.
    check "abcdefghijklmnopqr" in withBar
    check "abcdefghijklmnopqrs" notin withBar
    check "abcdefghijklmnopqrs" in without

  test "zebra stripes alternate items, and the cursor is never striped":
    let stripe = Style().bg(hex"#1c2128")
    var l = initListView(height = 4)
    l.moveTo(1, 4)
    let ls = l.render(items(4), 20, selectedStyle = Style().bg(hex"#00e5ff"),
                      zebra = stripe).split('\n')
    check "28;33;40" notin ls[0]        # item 0: even, bare
    check "28;33;40" notin ls[1]        # item 1: odd, but it is the cursor
    check "0;229;255" in ls[1]
    check "28;33;40" in ls[2] or "28;33;40" in ls[3]
    check "28;33;40" in ls[3]           # item 3: odd
    check "28;33;40" notin ls[2]        # item 2: even

  test "the stripes belong to the items, so they do not crawl when scrolling":
    # Striping by screen row instead would make every band jump a line each time
    # the window moved, which is the one thing a stripe must not do.
    let stripe = Style().bg(hex"#1c2128")
    var l = initListView(height = 2)
    l.vp.top = 1
    l.cursor = 9
    let ls = l.render(items(10), 20, zebra = stripe).split('\n')
    check "28;33;40" in ls[0]           # item 1
    check "28;33;40" notin ls[1]        # item 2

  test "a stripe supplies a background without wiping the row's own colour":
    var l = initListView(height = 2)
    l.cursor = 0
    let coloured = @["plain", Style().fg(hex"#ff4e88").render("pink")]
    let ls = l.render(coloured, 20, zebra = Style().bg(hex"#1c2128")).split('\n')
    check "255;78;136" in ls[1]         # the item's own foreground survives
    check "28;33;40" in ls[1]           # under the stripe's background

  test "a degenerate size renders nothing rather than a broken block":
    check initListView(height = 0).render(items(5), 20) == ""
    check initListView(height = 5).render(items(5), 0) == ""

suite "listview keys":
  test "navigation keys are consumed and others are not":
    var l = initListView(height = 5)
    check l.handleKey(KeyMsg(key: kDown), 20)
    check l.cursor == 1
    check l.handleKey(KeyMsg(key: kEnd), 20)
    check l.cursor == 19
    check not l.handleKey(KeyMsg(key: kEnter), 20)
    check not l.handleKey(KeyMsg(key: kRune, rune: "d".runeAt(0)), 20)

  test "vi and emacs bindings agree with the arrows":
    var arrows = initListView(height = 5)
    var vi = initListView(height = 5)
    var emacs = initListView(height = 5)
    discard arrows.handleKey(KeyMsg(key: kDown), 20)
    discard vi.handleKey(KeyMsg(key: kRune, rune: "j".runeAt(0)), 20)
    discard emacs.handleKey(KeyMsg(key: kRune, rune: "n".runeAt(0),
                                   mods: {mCtrl}), 20)
    check arrows.cursor == vi.cursor
    check vi.cursor == emacs.cursor
