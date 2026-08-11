## A modal text editor: `vi`, cut down to the commands worth demonstrating.
##
## What this example is really about: **a key whose meaning depends on the keys
## before it.** Every other example here maps one key to one action, so its
## whole input layer is a `case $k`. Modal editing cannot be written that way —
## `d` is not a command, `2` is not a command, and `d` after `2` is a different
## thing from `d` after nothing. The shape that works is three pieces of state
## and no branching over "which key am I expecting next":
##
## ```nim
## m.mode      # which set of keys is live at all
## m.count     # the digits typed so far, 0 for none
## m.pending   # the keys of a command that is not finished yet
## ```
##
## Every key appends to `pending` and the result is looked up whole. A prefix
## that could still grow (`d`, `g`) is kept and the function returns; anything
## else resolves and clears. That is the entire dispatcher, and adding `y` or
## `>` to it is one more branch rather than one more mode flag.
##
## The other thing it carries is what an application owns when the library
## stops. There is no editable multi-line component here on purpose —
## `TextArea` is read-only and `TextInput` is one line — so the buffer, the
## cursor and undo are the model's, and what gets reused is the parts that are
## not about editing: `Viewport` for the window that follows the cursor,
## `TextInput` for the `:` line, and `sliceVisible` for the horizontal scroll,
## which matters because a window into the middle of a line has to carry the
## escape sequences that came before it or the cursor cell bleeds to the edge.
##
## Two off-by-ones are the whole difference between this and a plain editor,
## and both are load-bearing rather than quirks:
##
## * **In normal mode the cursor is *on* a character; in insert mode it is
##   *between* two.** So `cx` may be `line.len` in insert and at most
##   `line.len - 1` in normal, which is why `esc` steps left and why `$` lands
##   where it does. One clamp, `clampCx`, holds it.
## * **`j` and `k` return to a column, not to a rune index.** Those are the
##   same number only until a line contains something two columns wide, and the
##   library's rule is that column arithmetic goes through `runeWidth`.
##
##   nim c -r --path:src examples/vim.nim [file]

import std/[os, strutils, strformat, unicode, sequtils]
import nimtui

type
  Mode = enum
    mNormal, mInsert, mCommand

  Snapshot = object
    lines: seq[seq[Rune]]
    cy, cx: int

  Model = object
    path: string               ## "" for a scratch buffer, which `:w` refuses
    lines: seq[seq[Rune]]      ## never empty: an editor always has a line
    cy, cx: int                ## cursor line, and cursor *rune* within it
    goalCol: int               ## the column j and k try to get back to
    mode: Mode
    count: int                 ## the numeric prefix, 0 when none was typed
    pending: string            ## an unfinished command, "" when there is none
    yank: seq[seq[Rune]]       ## the register, linewise only
    undo: seq[Snapshot]
    cmd: TextInput             ## the `:` line
    vp: Viewport
    xOffset: int               ## horizontal scroll, in columns
    dirty: bool
    status: string
    size: TermSize
    theme: Theme

const
  TabWidth = 4
  MaxUndo = 200
  Sample = """
nimtui vim

This is a scratch buffer: there is no file behind it, so :w has nothing to
write to and says so. Pass a path on the command line to edit something real.

Motions:  h j k l   0 ^ $   w b e   gg G   ctrl+d ctrl+u
Edits:    i a I A   o O   x D   dd dw d$   yy p   u
Counts:   3j  5x  2dd  10G
Also:     ctrl+z to background, fg to come back
Command:  :w  :q  :q!  :wq  :42

Every one of those is decided in one place — normalKey, at the bottom of the
update section. A key arrives, it is appended to what was pending, and the
result is either a command, a prefix worth keeping, or nothing.
"""

# --- text in and out ----------------------------------------------------------

proc sanitise(s: string): seq[Rune] =
  ## One source line as runes, with nothing in it the terminal would act on.
  ##
  ## The library's flatten-before-you-measure rule at this example's boundary
  ## with the outside world, and the tab half of it is `ansi.expandTabs`. Done
  ## on the way *in* rather than at draw time, which is the difference between
  ## an editor and a viewer: a tab the editor pretends is four columns wide is
  ## four screen positions `cx` cannot address, so the buffer has to hold what
  ## will be drawn.
  ##
  ## `oneLine` is the wrong tool for the rest, for `TextInput`'s reason: it
  ## preserves escape sequences, and an `ESC` in a `seq[Rune]` is not styling —
  ## it is a rune the cursor can sit on and `runeWidth` counts as nothing.
  for r in expandTabs(s, TabWidth).runes:
    result.add(if r.isControl: Rune(' ') else: r)

proc setText(m: var Model, s: string) =
  m.lines = @[]
  for line in s.splitLines: m.lines.add sanitise(line)
  # A file ending in a newline splits to a trailing empty element, and `text`
  # below writes a newline after the last line — so keeping it adds a blank
  # line to the file on every save. Reading and writing with no edit in between
  # has to be a no-op, or the editor damages what it was pointed at.
  if m.lines.len > 1 and m.lines[^1].len == 0: m.lines.setLen m.lines.len - 1
  if m.lines.len == 0: m.lines.add sanitise("")

proc text(m: Model): string =
  var parts = newSeqOfCap[string](m.lines.len)
  for line in m.lines: parts.add $line
  parts.join("\n") & "\n"

# --- cursor arithmetic --------------------------------------------------------

## `columnOf` and `runeAtColumn` come from `nimtui/width`: the cursor is a rune
## index and the screen wants a column, and those are the same number only until
## a line holds something two columns wide.

proc clampCx(m: var Model) =
  ## The one place the two cursors differ. Insert mode may sit one past the end
  ## of the line, because that is where you type; normal mode may not, because
  ## it is sitting *on* a character and there is no character there.
  let n = m.lines[m.cy].len
  m.cx = clamp(m.cx, 0, if m.mode == mInsert: n else: max(n - 1, 0))

proc setGoal(m: var Model) =
  m.goalCol = columnOf(m.lines[m.cy], m.cx)

proc toLine(m: var Model, y: int) =
  ## Vertical movement, which alone preserves `goalCol` — every other motion
  ## sets it. That is what makes `j` down a short line and on again come back
  ## out at the column it started from.
  m.cy = clamp(y, 0, m.lines.len - 1)
  m.cx = runeAtColumn(m.lines[m.cy], m.goalCol)
  m.clampCx()

# --- motions ------------------------------------------------------------------
#
# A word here is a run of non-blanks, which is vim's `W` rather than its `w`.
# Real `w` splits on punctuation too, so `foo.bar` is three words; that is a
# second character class and a table to go with it, and it is not what this
# example is about.

proc firstNonBlank(line: seq[Rune]): int =
  while result < line.len and line[result].isWhiteSpace: inc result
  if result >= line.len: result = max(line.len - 1, 0)

proc nextWord(m: var Model) =
  var
    l = m.cy
    c = m.cx
  while c < m.lines[l].len and not m.lines[l][c].isWhiteSpace: inc c
  while true:
    if c >= m.lines[l].len:
      if l + 1 >= m.lines.len: break
      inc l
      c = 0
      if m.lines[l].len == 0: break   # an empty line is a word of its own
    elif m.lines[l][c].isWhiteSpace: inc c
    else: break
  m.cy = l
  m.cx = c

proc prevWord(m: var Model) =
  var
    l = m.cy
    c = m.cx - 1
  while true:
    if c < 0:
      if l == 0:
        c = 0
        break
      dec l
      c = m.lines[l].len - 1
      if c < 0:
        c = 0
        break
    elif m.lines[l][c].isWhiteSpace: dec c
    else: break
  while c > 0 and not m.lines[l][c - 1].isWhiteSpace: dec c
  m.cy = l
  m.cx = max(c, 0)

proc wordEnd(m: var Model) =
  var
    l = m.cy
    c = m.cx + 1
  while true:
    if c >= m.lines[l].len:
      if l + 1 >= m.lines.len:
        c = max(m.lines[l].len - 1, 0)
        break
      inc l
      c = 0
    elif m.lines[l][c].isWhiteSpace: inc c
    else: break
  while c + 1 < m.lines[l].len and not m.lines[l][c + 1].isWhiteSpace: inc c
  m.cy = l
  m.cx = max(c, 0)

# --- editing ------------------------------------------------------------------

proc snapshot(m: var Model) =
  ## Called by every command that changes the buffer, before it changes it.
  ##
  ## Whole-buffer copies, which is the wrong answer above a few thousand lines
  ## and the only answer worth writing below that: the alternative is a diff
  ## representation, and undo is not the idea this example carries.
  m.undo.add Snapshot(lines: m.lines, cy: m.cy, cx: m.cx)
  if m.undo.len > MaxUndo: m.undo.delete(0)
  m.dirty = true

proc undo(m: var Model) =
  if m.undo.len == 0:
    m.status = "already at oldest change"
    return
  let s = m.undo.pop()
  m.lines = s.lines
  m.cy = min(s.cy, m.lines.len - 1)
  m.cx = s.cx
  m.clampCx()
  m.status = ""

proc deleteLines(m: var Model, count: int) =
  m.snapshot()
  let last = min(m.cy + count, m.lines.len)
  m.yank = m.lines[m.cy ..< last]
  m.lines.delete(m.cy ..< last)
  if m.lines.len == 0: m.lines.add @[]   # a buffer always has a line
  m.cy = min(m.cy, m.lines.len - 1)
  m.cx = firstNonBlank(m.lines[m.cy])
  m.clampCx()

proc deleteRunes(m: var Model, count: int) =
  let line = m.lines[m.cy]
  if line.len == 0: return
  m.snapshot()
  let last = min(m.cx + count, line.len)
  m.lines[m.cy].delete(m.cx ..< last)
  m.clampCx()

proc openLine(m: var Model, below: bool) =
  m.snapshot()
  let at = if below: m.cy + 1 else: m.cy
  # Named rather than written `@[]`, which is not the same thing: `sequtils`
  # adds an `insert(dest, src: openArray[T], pos)` beside `system`'s
  # `insert(x, item, i)`, and an empty literal matches the first — so `o`
  # inserts nothing at all and the text typed after it lands on the line below.
  var blank: seq[Rune]
  m.lines.insert(blank, at)
  m.cy = at
  m.cx = 0
  m.mode = mInsert

proc splitLine(m: var Model) =
  m.snapshot()
  let tail = m.lines[m.cy][m.cx .. ^1]
  m.lines[m.cy].setLen m.cx
  m.lines.insert(tail, m.cy + 1)
  inc m.cy
  m.cx = 0

proc joinBack(m: var Model) =
  ## Backspace at column zero: the line above absorbs this one.
  if m.cy == 0: return
  m.snapshot()
  let above = m.lines[m.cy - 1].len
  m.lines[m.cy - 1].add m.lines[m.cy]
  m.lines.delete(m.cy)
  dec m.cy
  m.cx = above

proc insertRunes(m: var Model, rs: seq[Rune]) =
  m.snapshot()
  m.lines[m.cy].insert(rs, m.cx)
  m.cx += rs.len

proc paste(m: var Model) =
  if m.yank.len == 0:
    m.status = "nothing to put"
    return
  m.snapshot()
  m.lines.insert(m.yank, m.cy + 1)
  inc m.cy
  m.cx = firstNonBlank(m.lines[m.cy])
  m.clampCx()

# --- the `:` line -------------------------------------------------------------

proc save(m: var Model): bool =
  if m.path.len == 0:
    m.status = "no file name"
    return false
  try:
    writeFile(m.path, m.text)
    m.dirty = false
    m.status = &"\"{m.path.lastPathPart}\" {m.lines.len}L written"
    true
  except CatchableError as e:
    m.status = e.msg.splitLines[0]
    false

proc runCommand(m: var Model, cmd: string): Cmd =
  ## Returns a `Cmd` because one of these quits, which is the loop's business
  ## and not the model's.
  let c = cmd.strip
  case c
  of "": discard
  of "q":
    if m.dirty: m.status = "unsaved changes (:q! to discard)"
    else: return quitCmd()
  of "q!": return quitCmd()
  of "w": discard m.save()
  of "wq", "x":
    if m.save(): return quitCmd()
  else:
    if c.allCharsInSet({'0' .. '9'}):
      m.goalCol = 0
      m.toLine(parseInt(c) - 1)
      m.cx = firstNonBlank(m.lines[m.cy])
      m.setGoal()
    else:
      m.status = &"not an editor command: {c}"

# --- normal mode --------------------------------------------------------------

proc normalKey(m: var Model, s: string): Cmd =
  ## The dispatcher. `s` is one key; what it means is `pending & s`.
  ##
  ## Three exits, and keeping them straight is the whole trick: a *prefix*
  ## returns with `pending` set and the count untouched, a *command* falls out
  ## of the case and clears both, and a *digit* accumulates. Anything that
  ## cleared `pending` on its way in would make `dd` two failed `d`s.
  if m.pending.len == 0 and s.len == 1 and s[0] in {'1' .. '9'} or
     (m.count > 0 and s == "0"):
    m.count = m.count * 10 + parseInt(s)
    return

  let
    cmd = m.pending & s
    n = max(m.count, 1)        # "no count" and "one" mean the same to a motion
    counted = m.count > 0
      ## Not the same question as `n > 1`, and `gg` and `G` are where the two
      ## come apart: bare `G` is the last line and `1G` is the first, so those
      ## two need to know a count was typed at all. Read here because the case
      ## below runs with `count` already cleared.

  # A prefix, not a command: keep it and wait for the rest. Returning early is
  # what leaves `count` alone, so `2dd` still knows it is a two.
  if cmd in ["d", "g", "y"]:
    m.pending = cmd
    return

  m.pending = ""
  m.count = 0
  m.status = ""

  case cmd
  of "h", "left":
    m.cx = max(m.cx - n, 0)
    m.setGoal()
  of "l", "right":
    m.cx += n
    m.clampCx()
    m.setGoal()
  of "j", "down": m.toLine(m.cy + n)
  of "k", "up": m.toLine(m.cy - n)
  of "0", "home":
    m.cx = 0
    m.setGoal()
  of "^":
    m.cx = firstNonBlank(m.lines[m.cy])
    m.setGoal()
  of "$", "end":
    m.cx = max(m.lines[m.cy].len - 1, 0)
    # Deliberately not `setGoal`: in vim `$` is sticky, so `$` then `j` lands at
    # the end of the next line however long it is. One assignment, and leaving
    # it out is the difference nobody can name but everybody notices.
    m.goalCol = high(int) div 2
  of "w":
    for _ in 1 .. n: m.nextWord()
    m.setGoal()
  of "b":
    for _ in 1 .. n: m.prevWord()
    m.setGoal()
  of "e":
    for _ in 1 .. n: m.wordEnd()
    m.setGoal()
  of "gg":
    m.goalCol = 0
    m.toLine(if counted: n - 1 else: 0)
    m.cx = firstNonBlank(m.lines[m.cy])
    m.setGoal()
  of "G":
    m.goalCol = 0
    m.toLine(if counted: n - 1 else: m.lines.len - 1)
    m.cx = firstNonBlank(m.lines[m.cy])
    m.setGoal()
  of "ctrl+d", "pgdown":
    m.vp.halfPageDown m.lines.len
    m.toLine(m.cy + max(m.vp.height div 2, 1))
  of "ctrl+u", "pgup":
    m.vp.halfPageUp m.lines.len
    m.toLine(m.cy - max(m.vp.height div 2, 1))
  of "i": m.mode = mInsert
  of "a":
    m.mode = mInsert
    m.cx = min(m.cx + 1, m.lines[m.cy].len)
  of "I":
    m.mode = mInsert
    m.cx = 0
  of "A":
    m.mode = mInsert
    m.cx = m.lines[m.cy].len
  of "o": m.openLine(below = true)
  of "O": m.openLine(below = false)
  of "x", "delete": m.deleteRunes n
  of "D", "d$":               # the same command, and vim spells it both ways
    m.snapshot()
    m.lines[m.cy].setLen m.cx
    m.clampCx()
  of "dd": m.deleteLines n
  of "dw", "de":
    # An operator applied to a motion, done the way that generalises: run the
    # motion on a copy and delete what it moved over. Writing out where `w`
    # lands, here as well as in `nextWord`, is how `d` and `w` come to disagree
    # about what a word is the first time either is touched.
    #
    # A `dw` that reaches the next line stops at the end of this one, which is
    # vim's own rule and the one place its behaviour surprises people.
    var probe = m
    for _ in 1 .. n:
      if cmd == "dw": probe.nextWord() else: probe.wordEnd()
    let stop = if probe.cy != m.cy: m.lines[m.cy].len
               elif cmd == "dw": probe.cx
               else: probe.cx + 1        # `e` is inclusive of its landing rune
    if stop > m.cx: m.deleteRunes(stop - m.cx)
  of "d0":
    m.snapshot()
    m.lines[m.cy].delete(0 ..< m.cx)
    m.cx = 0
  of "yy":
    let last = min(m.cy + n, m.lines.len)
    m.yank = m.lines[m.cy ..< last]
    m.status = &"{m.yank.len} lines yanked"
  of "p": m.paste()
  of "u":
    for _ in 1 .. n: m.undo()
  of ":":
    m.mode = mCommand
    m.cmd.clear()
  of "ctrl+z":
    # What real vim does with it, and the one binding here the runtime could not
    # have made itself: ISIG is off, so this arrives as an ordinary key.
    result = suspendCmd()
  of "ctrl+c":
    m.status = "type :q to quit"
  else:
    if cmd.len > 0: m.status = &"not a command: {cmd}"

# --- update -------------------------------------------------------------------

proc gutterWidth(m: Model): int = len($m.lines.len) + 1
proc textWidth(m: Model): int = max(m.size.width - m.gutterWidth, 1)

proc syncScroll(m: var Model) =
  ## Both scroll axes derived from the cursor, so nothing has to remember to
  ## move them: vertical through `Viewport`, horizontal by hand because a
  ## column is not a line and `Viewport` counts lines.
  m.vp.height = max(m.size.height - 2, 1)
  m.vp.ensureVisible(m.cy, m.lines.len)
  let
    col = columnOf(m.lines[m.cy], m.cx)
    w = m.textWidth
  if col < m.xOffset: m.xOffset = col
  elif col >= m.xOffset + w: m.xOffset = col - w + 1

proc update(m: Model, msg: Msg): (Model, Cmd) =
  # The model is a value, so this copies the buffer on every keystroke. Right
  # at this scale and the thing to change first at a much larger one — the Elm
  # contract is about `update` being a function, not about how the seq gets
  # there, so a rope or an explicit `var` buffer swaps in without touching the
  # runtime.
  result = (m, nil)

  if result[0].size.handleResize(msg):
    result[0].syncScroll()
    return

  if msg of PasteMsg and result[0].mode == mInsert:
    # Bracketed paste earns its keep here more than anywhere: without it every
    # pasted newline is a `kEnter`, which is *correct* — it splits the line —
    # but arrives as one `update` and one snapshot per character, so a 4 KB
    # paste is four thousand copies of the buffer and four thousand undo steps
    # to walk back out of.
    result[0].snapshot()
    let lines = PasteMsg(msg).text.splitLines
    if lines.len == 1:
      result[0].lines[result[0].cy].insert(sanitise(lines[0]), result[0].cx)
      result[0].cx += sanitise(lines[0]).len
    else:
      let tail = result[0].lines[result[0].cy][result[0].cx .. ^1]
      result[0].lines[result[0].cy].setLen result[0].cx
      result[0].lines[result[0].cy].add sanitise(lines[0])
      for i in 1 ..< lines.len:
        result[0].lines.insert(sanitise(lines[i]), result[0].cy + i)
      result[0].cy += lines.len - 1
      result[0].cx = result[0].lines[result[0].cy].len
      result[0].lines[result[0].cy].add tail
    result[0].syncScroll()
    return

  if not (msg of KeyMsg): return
  let
    k = KeyMsg(msg)
    s = $k

  case result[0].mode
  of mNormal:
    result[1] = result[0].normalKey(s)

  of mInsert:
    case s
    of "esc", "ctrl+c":
      result[0].mode = mNormal
      # Back onto a character: insert mode's cursor is between two runes and
      # normal mode's is on one, so leaving without this puts it one past the
      # last thing typed.
      result[0].cx = max(result[0].cx - 1, 0)
      result[0].clampCx()
      result[0].setGoal()
    of "enter": result[0].splitLine()
    of "backspace":
      if result[0].cx == 0: result[0].joinBack()
      else:
        result[0].snapshot()
        result[0].lines[result[0].cy].delete(result[0].cx - 1)
        dec result[0].cx
    of "delete":
      if result[0].cx < result[0].lines[result[0].cy].len:
        result[0].snapshot()
        result[0].lines[result[0].cy].delete(result[0].cx)
    of "tab":
      # A tab is expanded here for `sanitise`'s reason: the buffer holds what
      # will be drawn, so the cursor can address every column of it.
      let pad = TabWidth - (columnOf(result[0].lines[result[0].cy],
                                  result[0].cx) mod TabWidth)
      var spaces = newSeq[Rune](pad)
      for i in 0 ..< pad: spaces[i] = Rune(' ')
      result[0].insertRunes(spaces)
    of "space": result[0].insertRunes @[Rune(' ')]
    of "left": result[0].cx = max(result[0].cx - 1, 0)
    of "right":
      result[0].cx = min(result[0].cx + 1, result[0].lines[result[0].cy].len)
    of "up": result[0].toLine(result[0].cy - 1)
    of "down": result[0].toLine(result[0].cy + 1)
    of "home": result[0].cx = 0
    of "end": result[0].cx = result[0].lines[result[0].cy].len
    else:
      if k.key == kRune and mCtrl notin k.mods and mAlt notin k.mods:
        result[0].insertRunes @[k.rune]

  of mCommand:
    case s
    of "enter":
      result[0].mode = mNormal
      result[1] = result[0].runCommand(result[0].cmd.text)
      result[0].cmd.clear()
    of "esc", "ctrl+c":
      result[0].mode = mNormal
      result[0].cmd.clear()
      result[0].status = ""
    else:
      # Backspacing off the end of an empty `:` line leaves command mode, the
      # way it does in vim — otherwise the only way out is a key the user is
      # trying to delete with.
      if s == "backspace" and result[0].cmd.isEmpty:
        result[0].mode = mNormal
      else:
        discard result[0].cmd.handleKey(k)

  result[0].clampCx()
  result[0].syncScroll()

# --- view ---------------------------------------------------------------------

proc renderRow(m: Model, i, width: int): string =
  ## One buffer line, cursor included, windowed to the horizontal scroll.
  ##
  ## The cursor is a reversed cell rather than the terminal's own, which is what
  ## every component here does — the renderer stays in charge of the real one.
  ## That is also why the slice has to be `sliceVisible`: the reversed cell is
  ## an escape sequence, and a naive cut at `xOffset` either loses the escapes
  ## that opened a run or keeps the one that opened the cursor and reverses the
  ## rest of the line.
  let
    line = m.lines[i]
    showCursor = i == m.cy and m.mode != mCommand
  var s = ""
  for j, r in line:
    if showCursor and j == m.cx: s.add Style().reverse().render($r)
    else: s.add r
  if showCursor and m.cx >= line.len: s.add Style().reverse().render(" ")
  padVisible(sliceVisible(s, m.xOffset, width), width)

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let
    t = m.theme
    w = m.size.width
    gw = m.gutterWidth
    tw = m.textWidth

  var rows: seq[string]
  for i in m.vp.top ..< min(m.vp.top + m.vp.height, m.lines.len):
    let num = align($(i + 1), gw - 1) & " "
    rows.add (if i == m.cy: t.accentStyle.render(num)
              else: t.mutedStyle.render(num)) & m.renderRow(i, tw)
  # `~` for the rows past the end of the buffer, which is not decoration: it is
  # the only thing distinguishing a short file from a long one scrolled to its
  # last line, and both draw the same number of rows.
  while rows.len < m.vp.height:
    rows.add t.mutedStyle.render("~") & spaces(w - 1)

  let
    modeName = case m.mode
               of mNormal: " NORMAL "
               of mInsert: " INSERT "
               of mCommand: " COMMAND "
    modeColour = case m.mode
                 of mNormal: t.accent
                 of mInsert: t.success
                 of mCommand: t.warn
    name = if m.path.len == 0: "[No Name]" else: m.path.lastPathPart
    percent = if m.lines.len <= 1: 100
              else: (m.cy * 100) div (m.lines.len - 1)
    bar = statusBar(
      Style().fg(t.bg).bg(modeColour).bold().render(modeName) &
        &" {name}" & (if m.dirty: " [+]" else: ""),
      "",
      &"{m.cy + 1}:{columnOf(m.lines[m.cy], m.cx) + 1}  {percent}% ",
      w, t.selectionStyle)

  # Bottom line: the `:` field, then a message, then the keys — and whatever it
  # holds, the *pending* command sits on its right, because a state machine
  # that shows nothing while it waits is one that looks broken when it waits by
  # mistake.
  let waiting =
    if m.count > 0 or m.pending.len > 0:
      t.warnStyle.render((if m.count > 0: $m.count else: "") & m.pending & " ")
    else: ""
  let bottom =
    if m.mode == mCommand:
      t.accentStyle.render(":") & m.cmd.render(max(w - 1, 1))
    elif m.status.len > 0:
      statusBar(" " & t.warnStyle.render(m.status), "", waiting, w)
    else:
      statusBar(" " & hints({"i": "insert", "esc": "normal", "dd": "delete",
                             "u": "undo", ":w": "write", ":q": "quit"}),
                "", waiting, w)

  joinVertical(rows.join("\n"), bar, bottom)

when isMainModule:
  var model = Model(theme: DefaultTheme, cmd: initTextInput())
  if paramCount() > 0:
    model.path = paramStr(1)
    if fileExists(model.path):
      model.setText readFile(model.path)
    else:
      model.setText ""
      model.status = &"\"{model.path.lastPathPart}\" [New]"
  else:
    model.setText Sample.strip(leading = true, trailing = false)

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor,
                                poBracketedPaste}).run()
