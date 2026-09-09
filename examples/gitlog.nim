## A git repository browser: commits, the files each touched, and the diff.
##
## **What this example is really about: the seams.** Every other example here
## carries one idea, which is what lets the table in `CLAUDE.md` say what each is
## for. This one is deliberately the other kind — the failures it demonstrates
## exist only where two features meet, and no single-idea example can reach them.
## Six of them, in the order they appear below:
##
## * **Key dispatch with four levels.** A modal overlay, then a mode, then the
##   focused component, then the application's own bindings. `form` shows the
##   third alone and `todo` the second alone; the order they compose in is the
##   thing every real application has to get right and nothing else here shows.
## * **A theme derived from the terminal's actual background.** `poQueryBackground`
##   exists so a palette can be built from `TerminalBgMsg` before the first frame.
##   A diff is the case that needs it: the backgrounds behind added and removed
##   lines are mixed a few percent *from the real background*, so they read as a
##   tint on the user's own terminal rather than as two colours chosen in advance
##   that are wrong on half of them. `ckDefault` is the normal answer, not an
##   error, and the fallback is a foreground-only diff.
## * **Text that arrives already styled.** `c` toggles between colouring the diff
##   here and taking git's own `--color=always` output. The second is what
##   `TextArea.lineStyle`'s `renderOver` and `sliceVisible`'s escape re-emission
##   are for, and scrolling such a pane sideways is the only way to see them work.
## * **Slow loading that stays interruptible.** History arrives a page at a time
##   through a chain of `after(DurationZero, …)` commands, with a generation
##   counter so changing the filter abandons the pages still in flight instead of
##   racing them.
## * **Debouncing.** Holding `j` down must not run a `git show` per keypress. The
##   selection schedules a load `DiffDebounce` in the future and a second
##   generation counter drops it if the selection moved again first.
## * **A mouse against a real layout**, which is the one this library cannot
##   currently help with — see the note on `regions`_ below.
##
## Also, in passing: **which branch a commit is on, asked both ways round.** The
## decorations `git log` prints in parentheses are one direction — a ref points
## *at* this commit — and they ride along in the log format as `%D`, drawn as
## chips on the row. They only ever mark tips, though, so one commit past the
## head of a branch there is nothing left saying where you are; the other
## direction, every branch that can *reach* the commit, is a `git branch
## --contains` in the debounced load beside the patch, named in the header. Also
## `execCmd` twice over (`enter` hands the terminal to `git
## show`, which brings its own pager; `E` opens `$EDITOR` on the file under the
## cursor and reloads afterwards rather than trusting the screen), `suspendCmd`,
## bracketed paste into the filter field, a `FocusMsg` used for the one thing it
## is good for, `ErrorMsg` from real failures — run it outside a repository —
## and `runHeadless` as a self-test that needs no repository and spawns nothing.
##
##   nim c -r --path:src examples/gitlog.nim [path]
##   ./bin/gitlog --selftest

import std/[os, osproc, streams, strutils, strformat, times, math, unicode]
import nimtui

const
  PageSize = 150
    ## Commits per slice. Sized so one `git log` is a few milliseconds — see the
    ## note on `pageCmd`_ about what bounds a slice when the work is a subprocess.
  MaxDiffLines = 4000
  DiffDebounce = initDuration(milliseconds = 120)
  SpinInterval = initDuration(milliseconds = 90)
  StatusHold = initDuration(seconds = 4)
  Sep = '\x1f'
    ## git's own field separator (`%x1f`), so a subject containing a tab or a
    ## pipe cannot split a record. A commit subject is arbitrary user text.
  LogFormat = "%H%x1f%h%x1f%an%x1f%at%x1f%D%x1f%s"
    ## `%D` is the decorations — the branch and tag names pointing *at* this
    ## commit, which is what `git log` prints in parentheses. It goes before the
    ## subject rather than after it so the subject stays the last field: a
    ## separator byte in arbitrary user text then truncates only the subject,
    ## which is the property the separator was chosen for in the first place.
  MaxChips = 30
    ## The most columns of decoration a commit row will give up to. A commit
    ## with fourteen release tags on it must not push its own subject off the
    ## row — the decorations are an annotation on the line, not the line.
  MinSubject = 12
    ## Columns of subject a decoration may never take. Twelve is about two
    ## words, which is what it takes for a subject to still be recognisable as
    ## the one you are looking for once the decorations have had the rest.
  MinChip = 5
    ## The narrowest an elided decoration may be cut to. Below this it says
    ## nothing a bare marker would not, and a bare marker is not what it is.
  MaxContain = 3
    ## Branches named in the header before the rest become a count. The question
    ## being answered is "is this on my branch", not "list every ref".

type
  Commit = object
    sha, short, author, subject: string
    at: int64                    ## author date, seconds since the epoch
    refs: string                 ## `%D`, verbatim: "HEAD -> main, tag: v1.2"

  BranchRef = object
    ## One answer from `git branch --contains`. `remote` is carried rather than
    ## re-derived from a `/` in the name, because a local branch may legally be
    ## called `feature/x` and would then be filed under the wrong colour.
    name: string
    remote: bool

  FileStat = object
    path: string
    added, removed: int
    binary: bool

  Pane = enum
    pCommits = "commits"
    pDiff = "diff"

  Mode = enum
    mBrowse, mFilter, mHelp

  # --- messages ---------------------------------------------------------------

  NextPageMsg = ref object of Msg
    ## The yield between two pages. `after(DurationZero, …)` takes a message
    ## rather than a command, and the work is IO and so has to happen inside a
    ## command — so the chain alternates between the two: this message is the
    ## point at which the loop gets a turn, and its handler issues the command
    ## that does the reading.
    gen: int
    skip: int

  PageMsg = ref object of Msg
    gen: int                     ## which load this page belongs to
    skip: int
    commits: seq[Commit]

  DiffLoadMsg = ref object of Msg
    ## The debounce timer firing. Still has to be checked against `diffGen`:
    ## the timer fires whether or not the selection stayed put.
    gen: int
    sha: string

  DiffMsg = ref object of Msg
    gen: int
    sha: string
    patch: string
    numstat: string
    branches: string             ## `git branch --contains`, unparsed

  RepoMsg = ref object of Msg
    root, branch, head: string

  SpinMsg = ref object of Msg
  ClearStatusMsg = ref object of Msg

  ReloadMsg = ref object of Msg
    ## A child process has exited. Whatever it was may have changed the
    ## repository — `git commit --amend` from inside `$EDITOR` is the obvious
    ## one — so the history on screen is of the version from before.

  Model = object
    root, branch, head: string
    commits: seq[Commit]
    filtered: seq[int]           ## indices into `commits`, in display order
    list: ListView
    diff: TextArea
    longest: int                 ## the widest line the diff pane holds
    files: seq[FileStat]
    containedIn: seq[BranchRef]  ## the branches holding the selected commit
    filter: TextInput
    mode: Mode
    focus: Pane
    gen, diffGen: int
    loading, loadedAll: bool
    gitColour: bool              ## let git colour the patch, rather than us
    diffOf: string               ## the sha the diff pane currently holds
    frame: int
    animate: bool
    status: string
    statusIsError: bool
    size: TermSize
    theme: Theme
    bg: Color                    ## what the terminal said, or `ckDefault`
    addStyle, delStyle, hunkStyle, paneStyle: Style

# --- talking to git -----------------------------------------------------------

proc git(root: string, args: varargs[string]): string =
  ## Run git in `root` and return its standard output, raising on a non-zero
  ## exit.
  ##
  ## Called only from inside a `Cmd`, which is what makes the raise the right
  ## thing to do: the runtime turns it into an `ErrorMsg` and the message lands
  ## on the status line, rather than unwinding the loop with the terminal in raw
  ## mode. Pointing this at a directory that is not a repository is the shortest
  ## way to see that happen.
  ##
  ## `--no-pager` because git pages by default when its output is a terminal,
  ## and here the output is a pipe we are about to read — the one place in this
  ## file where git must *not* have the screen. `enter` is the other direction
  ## and deliberately omits it.
  var p = startProcess("git", workingDir = root,
                       args = @["--no-pager"] & @args,
                       options = {poUsePath})
  defer: p.close()
  # Read to EOF first, then wait: waiting first deadlocks as soon as the child
  # fills the pipe, which for `git show` on a large commit is immediate.
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    let err = p.errorStream.readAll().strip
    raise newException(IOError,
      "git " & args.join(" ") & " exited " & $code &
      (if err.len > 0: ": " & err.splitLines[0] else: ""))
  output

proc parseCommits(output: string): seq[Commit] =
  for line in output.splitLines:
    if line.len == 0: continue
    let f = line.split(Sep)
    if f.len < 6: continue
    result.add Commit(sha: f[0], short: f[1], author: f[2],
                      at: (try: parseBiggestInt(f[3]).int64 except ValueError: 0),
                      refs: f[4], subject: f[5])

proc repoCmd(path: string): Cmd =
  result = proc (): Msg =
    let root = git(path, "rev-parse", "--show-toplevel").strip
    # `--abbrev-ref` says "HEAD" on a detached head, which is worth showing as
    # itself rather than as a branch name that does not exist.
    let branch = git(root, "rev-parse", "--abbrev-ref", "HEAD").strip
    let head = git(root, "rev-parse", "--short", "HEAD").strip
    RepoMsg(root: root, branch: branch, head: head)

proc pageCmd(root: string, gen, skip: int): Cmd =
  ## One page of history, as one slice of a chain.
  ##
  ## The honest thing to say about this, because it is the constraint rather
  ## than a detail: a slice here is **one whole `git log` invocation**, and the
  ## loop is blocked for as long as that takes. `indexer` can cut its work to any
  ## size it likes because the work is its own; a subprocess is atomic, so the
  ## smallest slice available is the smallest useful page. At `PageSize` this is
  ## a few milliseconds per page on a large repository, which is a hitch rather
  ## than a freeze — and a repository with a hundred thousand commits still fills
  ## in progressively with the list scrollable throughout, which is the property
  ## worth having.
  ##
  ## `DurationZero` is a yield to the event loop, not a delay: anything already
  ## queued — a keypress, a resize — is handled before the next page runs.
  result = proc (): Msg =
    let output = git(root, "log", "--no-color", "--pretty=format:" & LogFormat,
                     "--skip=" & $skip, "-n", $PageSize)
    PageMsg(gen: gen, skip: skip, commits: parseCommits(output))

proc diffCmd(root, sha: string, colour: bool, gen: int): Cmd =
  ## Everything about the selected commit, in one debounced load.
  ##
  ## The containment question rides along with the patch deliberately. It is the
  ## same subprocess-shaped slice as everything else here, it is asked about the
  ## same commit, and — the part that matters — it is asked at the same *rate*:
  ## holding `j` must not run a `git branch --contains` per keypress any more
  ## than it may run a `git show` per keypress, and the debounce that already
  ## exists is the answer to both.
  result = proc (): Msg =
    let patch = git(root, "show", "--format=",
                    "--color=" & (if colour: "always" else: "never"), sha)
    let numstat = git(root, "show", "--format=", "--numstat", sha)
    # `-a`, so a commit that is only on a remote-tracking branch still has an
    # answer — which is the ordinary case when reading someone else's history.
    # `%(refname)` in full rather than `:short`, because the full form is what
    # says whether a ref is local or remote-tracking: `refs/heads/feature/x` and
    # `refs/remotes/origin/x` both shorten to something with a slash in it, and
    # a local branch called `feature/x` is perfectly legal. It also avoids the
    # default listing's `* ` marker on the current branch, which would only have
    # to be stripped off again.
    let branches = git(root, "branch", "-a", "--contains", sha,
                       "--format=%(refname)")
    DiffMsg(gen: gen, sha: sha, patch: patch, numstat: numstat,
            branches: branches)

proc spinCmd(): Cmd = after(SpinInterval, SpinMsg())

# --- derived state ------------------------------------------------------------

proc parseNumstat(s: string): seq[FileStat] =
  for line in s.splitLines:
    if line.len == 0: continue
    let f = line.split('\t')
    if f.len < 3: continue
    # A binary file is reported as "-\t-\tpath", which is not a count and must
    # not parse as zero — "no lines changed" and "not lines at all" are
    # different things and the table says so.
    if f[0] == "-":
      result.add FileStat(path: f[2], binary: true)
    else:
      result.add FileStat(path: f[2],
                          added: (try: parseInt(f[0]) except ValueError: 0),
                          removed: (try: parseInt(f[1]) except ValueError: 0))

proc parseBranches(output: string, current = ""): seq[BranchRef] =
  ## `git branch --contains`, with the local branches first.
  ##
  ## Order is the whole of the presentation here, because only the first few
  ## are shown: "is this commit on a branch of mine" is the question, and an
  ## answer that spends its three slots on `origin/*` mirrors of branches the
  ## reader already has is an answer to a different one.
  var
    remotes: seq[BranchRef]
    head: seq[BranchRef]         ## the branch that is checked out, if it is one
  for line in output.splitLines:
    let full = line.strip
    if full.len == 0: continue
    if full.startsWith("refs/heads/"):
      let name = full["refs/heads/".len .. ^1]
      # The checked-out branch goes first, ahead of the other locals. "Is this
      # commit on the branch I am on" is the question asked most often and the
      # one with the shortest patience for reading a list.
      if name == current and current.len > 0:
        head.add BranchRef(name: name, remote: false)
      else:
        result.add BranchRef(name: name, remote: false)
    elif full.startsWith("refs/remotes/"):
      let name = full["refs/remotes/".len .. ^1]
      # `origin/HEAD` is a symbolic ref standing for whatever the remote's
      # default branch is, so it is always a duplicate of the branch beside it.
      if not name.endsWith("/HEAD"):
        remotes.add BranchRef(name: name, remote: true)
    else: discard          # a tag or a note, which is not a branch
  result = head & result & remotes

proc matchesFilter(c: Commit, needle: string): bool =
  needle.len == 0 or
    needle in c.subject.toLowerAscii or
    needle in c.author.toLowerAscii or
    needle in c.refs.toLowerAscii or
    c.sha.startsWith(needle)

proc refilter(m: var Model) =
  ## Rebuild `filtered` and put the cursor somewhere that still exists.
  ##
  ## `ListView.sync` is the second half and is not optional: a filter narrowing
  ## to two commits with the cursor on the twelfth leaves it pointing past the
  ## end, and every read of the selection is then a bounds error.
  let needle = m.filter.text.strip.toLowerAscii
  m.filtered.setLen 0
  for i, c in m.commits:
    if c.matchesFilter(needle): m.filtered.add i
  m.list.sync m.filtered.len

proc selected(m: Model): Commit =
  if m.list.cursor < m.filtered.len: m.commits[m.filtered[m.list.cursor]]
  else: Commit()

proc scheduleDiff(m: var Model): Cmd =
  ## Ask for the selected commit's diff, later.
  ##
  ## Holding `j` down moves the cursor faster than `git show` can answer, and
  ## loading on every move would run one subprocess per keypress with every
  ## answer but the last thrown away. So the load is scheduled `DiffDebounce`
  ## ahead and stamped; a later move bumps `diffGen` and the earlier timer's
  ## message is dropped when it arrives.
  let c = m.selected
  if c.sha.len == 0 or c.sha == m.diffOf: return nil
  m.diffGen.inc
  after(DiffDebounce, DiffLoadMsg(gen: m.diffGen, sha: c.sha))

# --- the palette, from the terminal's own background --------------------------

proc applyBackground(m: var Model, bg: Color) =
  ## Build the palette once the terminal has said what it is sitting on.
  ##
  ## This is the whole reason `poQueryBackground` is worth the round trip. A
  ## diff needs two backgrounds that read as "this line changed" without
  ## fighting the text on them, and there is no pair of literals that works on
  ## both a near-black and a near-white terminal: pick for one and the other
  ## gets a slab of colour with unreadable text on it. Mixing a fifth of the way
  ## from *the background it is actually drawn on* is correct on both, and needs
  ## no foreground of its own.
  ##
  ## `ckDefault` — the terminal declined, or is not a terminal — is the normal
  ## case rather than an error, and the fallback has to be a real design and not
  ## a guess: no backgrounds at all, and the sign carried by the foreground,
  ## which is legible whatever it lands on.
  m.bg = bg
  if bg.kind == ckDefault:
    m.theme = DefaultTheme
    m.addStyle = Style().fg(m.theme.success)
    m.delStyle = Style().fg(m.theme.error)
    m.hunkStyle = Style().fg(m.theme.info)
    m.paneStyle = Style()
  else:
    let dark = bg.luminance < 0.5
    m.theme = derive(hex"#5ad1c0", dark = dark)
    m.addStyle = Style().bg(lerp(bg, m.theme.success, 0.20))
    m.delStyle = Style().bg(lerp(bg, m.theme.error, 0.20))
    m.hunkStyle = Style().fg(m.theme.info).bg(lerp(bg, m.theme.info, 0.10))
    # A tint under the whole diff pane, so it reads as a sheet of paper laid on
    # the terminal. It is also what puts `renderOver` on the hot path: with
    # git's own colours on, every line already carries escapes, and a plain
    # `render` would end this background at the first reset in the line and
    # leave the rest of the row bare.
    m.paneStyle = Style().bg(lerp(bg, m.theme.accent, 0.05))
  m.diff.lineStyle = m.paneStyle
  m.diff.scrollbarStyle = m.theme.mutedStyle

proc colourPatch(m: Model, patch: string): seq[string] =
  ## Colour a plain patch here, rather than letting git do it.
  ##
  ## The styling is baked into the strings because a `TextArea` draws every line
  ## with one `lineStyle` — per-line colour has nowhere else to live. Which is
  ## also why the pane does not wrap: `wrapText` splits on spaces and would cut
  ## a styled line between the escape that turns a background on and the one
  ## that turns it off. A diff wants horizontal scrolling anyway, which is what
  ## `h` / `l` and `←` / `→` do.
  for line in patch.splitLines:
    if result.len >= MaxDiffLines:
      result.add m.theme.warnStyle.render(
        &"… truncated at {MaxDiffLines} lines")
      break
    if line.startsWith("@@"): result.add m.hunkStyle.render(line)
    elif line.startsWith("+++") or line.startsWith("---"):
      result.add m.theme.mutedStyle.bold.render(line)
    elif line.startsWith("diff ") or line.startsWith("index "):
      result.add m.theme.mutedStyle.render(line)
    elif line.startsWith("+"): result.add m.addStyle.render(line)
    elif line.startsWith("-"): result.add m.delStyle.render(line)
    else: result.add line

proc plainPatch(patch: string): seq[string] =
  ## git's own colours, kept exactly as they arrived.
  for line in patch.splitLines:
    if result.len >= MaxDiffLines:
      result.add &"… truncated at {MaxDiffLines} lines"
      break
    result.add line

# --- geometry -----------------------------------------------------------------
#
# `MouseMsg.x`/`y` are 1-based screen cells, so acting on a click means knowing
# where each pane was drawn. `layout` computes exactly that and then returns a
# string, so the position is gone by the time this file has it — which is
# ROADMAP.md item 10, and this block is the evidence for it rather than a
# workaround worth copying. Every mouse-driven application ends up writing it.
#
# The mitigation, and the best available from outside the library: compute the
# rectangles *once*, in one proc, and have both `view` and the hit test read
# them. Two copies of this arithmetic drifting apart is how a click lands on the
# row above the one under the pointer.

type
  Rect = object
    x, y, w, h: int              ## 1-based, to match what a `MouseMsg` carries

  Regions = object
    commits, files, diff: Rect

proc contains(r: Rect, x, y: int): bool =
  r.w > 0 and r.h > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

proc inner(r: Rect): Rect =
  ## The interior of a panel: one cell of border on every side.
  Rect(x: r.x + 1, y: r.y + 1, w: max(r.w - 2, 0), h: max(r.h - 2, 0))

const
  HeaderRows = 2
  FooterRows = 1
  NarrowAt = 92                  ## below this the diff pane is dropped, not squeezed

proc regions(m: Model): Regions =
  ## Where every pane is, in screen cells. The single source for both the view
  ## and the hit test.
  let
    bodyTop = HeaderRows + 1
    bodyH = max(m.size.height - HeaderRows - FooterRows, 3)
    narrow = m.size.width < NarrowAt
    leftW = if narrow: m.size.width
            else: max(m.size.width * 2 div 5, 38)
    filesH = if bodyH >= 14: min(bodyH div 3, 9) else: 0
    commitsH = bodyH - filesH
  result.commits = Rect(x: 1, y: bodyTop, w: leftW, h: commitsH)
  if filesH > 0:
    result.files = Rect(x: 1, y: bodyTop + commitsH, w: leftW, h: filesH)
  if not narrow:
    result.diff = Rect(x: leftW + 1, y: bodyTop, w: m.size.width - leftW, h: bodyH)

proc relayout(m: var Model) =
  let r = m.regions
  m.list.vp.height = r.commits.inner.h
  m.list.sync m.filtered.len
  m.diff.resize(r.diff.inner.w, r.diff.inner.h)

# --- update -------------------------------------------------------------------

proc setStatus(m: var Model, s: string, isError = false): Cmd =
  m.status = s
  m.statusIsError = isError
  after(StatusHold, ClearStatusMsg())

proc openInPager(m: Model): Cmd =
  ## `git show` with the terminal handed to it — and *without* `--no-pager`,
  ## which is the whole difference: git brings its own pager, so this is a full
  ## screen of scrollable diff for no code at all. The runtime puts the terminal
  ## back, waits, and takes it again.
  let c = m.selected
  if c.sha.len == 0: return nil
  execCmd("git", ["-C", m.root, "show", "--color=always", c.sha],
          proc (r: ExecResult): Msg =
            if r.error != nil: ErrorMsg(error: r.error) else: nil)

proc editFile(m: Model): Cmd =
  ## `$EDITOR` on the first file the commit touched, as it stands in the working
  ## tree. Reloads afterwards rather than trusting what is on screen.
  if m.files.len == 0: return nil
  let path = m.root / m.files[0].path
  if not fileExists(path): return nil
  execCmd(getEnv("EDITOR", "vi"), [path],
          proc (r: ExecResult): Msg =
            if r.error != nil: ErrorMsg(error: r.error) else: ReloadMsg())

proc reload(m: var Model): Cmd =
  ## Start the history again from the top. `gen` is bumped, which is what
  ## abandons the pages still in flight — dropping their results is not enough,
  ## since each page's handler is what issues the next one.
  m.gen.inc
  m.commits.setLen 0
  m.filtered.setLen 0
  m.files.setLen 0
  m.containedIn.setLen 0
  m.diffOf = ""
  m.loading = true
  m.loadedAll = false
  m.list.sync 0
  batch(pageCmd(m.root, m.gen, 0), spinCmd())

proc onMouse(m: var Model, e: MouseMsg): Cmd =
  let r = m.regions
  case e.button
  of mbWheelUp, mbWheelDown:
    let dir = if e.button == mbWheelUp: -1 else: 1
    if r.diff.contains(e.x, e.y):
      # A pane of text scrolls by the customary three lines a notch; the commit
      # list moves a *selection*, and every step of one loads a patch, so a
      # three-row jump per notch both skips commits and issues three loads.
      m.diff.scrollBy(dir * 3)
    elif r.commits.contains(e.x, e.y):
      m.list.moveBy(dir, m.filtered.len)
      return m.scheduleDiff()
  of mbLeft:
    if e.action == maPress:
      if r.diff.contains(e.x, e.y):
        m.focus = pDiff
      elif r.commits.contains(e.x, e.y):
        m.focus = pCommits
        # The row under the pointer, from the same rectangle the view drew into.
        let idx = m.list.vp.top + (e.y - r.commits.inner.y)
        if idx >= 0 and idx < m.filtered.len:
          m.list.moveTo(idx, m.filtered.len)
          return m.scheduleDiff()
  else: discard
  nil

proc maxX(m: Model): int =
  ## How far right there is anything to see. Measured from the widest line the
  ## pane holds rather than stored as a column, because the pane can be resized
  ## without the patch being reloaded and the answer moves with the width.
  ##
  ## Without the bound, `l` slides the diff off into blank, which on screen is
  ## indistinguishable from a broken render.
  max(m.longest - m.diff.textWidth, 0)

proc onKey(m: var Model, k: KeyMsg): Cmd =
  ## The four levels, in the order they have to be tried.
  ##
  ## An overlay is first because it is *over* everything — a help screen that
  ## let `j` through to the list behind it would scroll something the user
  ## cannot see. The mode is next, because a text field has to be able to
  ## swallow `q`. Then the focused component, which answers whether the key was
  ## meant for it. Only what is left over is an application binding.

  # 1 — the overlay.
  if m.mode == mHelp:
    m.mode = mBrowse
    return nil

  # 2 — the mode.
  if m.mode == mFilter:
    if k.matches("esc"):
      m.mode = mBrowse
      m.filter.clear()
      m.refilter()
      return m.scheduleDiff()
    if k.matches("enter"):
      m.mode = mBrowse
      return nil
    if m.filter.handleKey(k):
      m.refilter()
      return m.scheduleDiff()
    return nil

  # 3 — the focused component. `handleKey` returning false is what lets `q`
  # reach the level below without either level knowing what the other binds.
  case m.focus
  of pCommits:
    if m.list.handleKey(k, m.filtered.len): return m.scheduleDiff()
  of pDiff:
    # `h` / `l` beside `←` / `→`: the pane does not wrap, so a long line runs
    # off the right and vim's horizontal pair is what a reader already driving
    # this with `j` / `k` reaches for. Translated to the arrows rather than
    # duplicating the scroll, so the clamp at column zero stays in `TextArea`;
    # `maxX` is the other end of it, which the pane cannot know because it holds
    # no opinion about how long its longest line is.
    #
    # `0` and `$` are the same pair at the ends of the travel. In vim they are
    # positions on a *line* rather than scroll amounts, which is exactly what
    # `xOffset` is here — the pane holds no cursor, so the leftmost and
    # rightmost columns it can show are the only two the pair can mean. `$`
    # needs `maxX` for the same reason `l` does, and is where the bound stops
    # being a clamp on an increment and becomes the answer itself.
    if k.matches("0"):
      m.diff.xOffset = 0
      return nil
    if k.matches("$"):
      m.diff.xOffset = m.maxX
      return nil
    let dk = if k.matches("h"): KeyMsg(key: kLeft)
             elif k.matches("l"): KeyMsg(key: kRight)
             else: k
    if m.diff.handleKey(dk):
      m.diff.xOffset = clamp(m.diff.xOffset, 0, m.maxX)
      return nil

  # 4 — the application.
  if k.matches("q", "ctrl+c"): return quitCmd()
  elif k.matches("ctrl+z"): return suspendCmd()
  elif k.matches("tab"):
    # Only where there is a second pane to move to.
    if m.regions.diff.w > 0:
      m.focus = if m.focus == pCommits: pDiff else: pCommits
  elif k.matches("?"): m.mode = mHelp
  elif k.matches("/"):
    m.mode = mFilter
    m.focus = pCommits
  elif k.matches("enter", "o"): return m.openInPager()
  elif k.matches("E"): return m.editFile()
  elif k.matches("r"): return m.reload()
  elif k.matches("c"):
    m.gitColour = not m.gitColour
    # Reload the patch rather than recolour what is held: with git's colours on
    # the escapes are in the bytes git sent, and they were never fetched.
    let sha = m.diffOf
    m.diffOf = ""
    m.diffGen.inc
    if sha.len > 0:
      return batch(diffCmd(m.root, sha, m.gitColour, m.diffGen),
                   m.setStatus(if m.gitColour: "patch coloured by git"
                               else: "patch coloured from the terminal background"))
  nil

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of TerminalBgMsg:
    # Before the first `WindowSizeMsg` and before `initCmd`, which is what makes
    # it safe to build the whole palette from it here.
    result[0].applyBackground TerminalBgMsg(msg).color

  elif result[0].size.handleResize(msg):
    result[0].relayout()

  elif msg of RepoMsg:
    let r = RepoMsg(msg)
    result[0].root = r.root
    result[0].branch = r.branch
    result[0].head = r.head
    result[1] = pageCmd(r.root, m.gen, 0)

  elif msg of PageMsg:
    let p = PageMsg(msg)
    # A page from a superseded load: drop it, and — the half that actually stops
    # the chain — do not issue its successor.
    if p.gen != m.gen: return
    result[0].commits.add p.commits
    result[0].refilter()
    if p.commits.len < PageSize:
      result[0].loading = false
      result[0].loadedAll = true
    else:
      result[1] = after(DurationZero,
                        NextPageMsg(gen: m.gen, skip: p.skip + PageSize))
    # The first page is what makes a selection exist, so the first diff is
    # scheduled from here rather than from a keypress.
    if p.skip == 0:
      result[1] = batch(result[1], result[0].scheduleDiff())

  elif msg of NextPageMsg:
    let n = NextPageMsg(msg)
    if n.gen == m.gen: result[1] = pageCmd(m.root, n.gen, n.skip)

  elif msg of DiffLoadMsg:
    let d = DiffLoadMsg(msg)
    if d.gen == m.diffGen:
      result[1] = diffCmd(m.root, d.sha, m.gitColour, d.gen)

  elif msg of DiffMsg:
    let d = DiffMsg(msg)
    if d.gen != m.diffGen: return
    result[0].diffOf = d.sha
    result[0].files = parseNumstat(d.numstat)
    result[0].containedIn = parseBranches(d.branches, m.branch)
    let lines =
      if d.patch.strip.len == 0:
        @["", "  (no diff — a merge commit shows none by default)"]
      elif m.gitColour: plainPatch(d.patch)
      else: m.colourPatch(d.patch)
    result[0].diff.setLines lines
    result[0].diff.scrollTo 0
    result[0].diff.xOffset = 0
    # `displayWidth`, not `len`: with `c` on, every one of these lines is mostly
    # escape sequences, which cost no columns.
    result[0].longest = 0
    for ln in lines:
      result[0].longest = max(result[0].longest, displayWidth(ln))

  elif msg of SpinMsg:
    result[0].frame.inc
    # Only while there is something to spin for, and only while somebody is
    # looking: an unfocused window animating is work nobody sees.
    if m.loading and m.animate: result[1] = spinCmd()

  elif msg of FocusMsg:
    result[0].animate = FocusMsg(msg).focused
    # Restart the spinner if it stopped while the window was in the background.
    if result[0].animate and m.loading: result[1] = spinCmd()

  elif msg of ReloadMsg:
    result[1] = result[0].reload()

  elif msg of ErrorMsg:
    result[0].loading = false
    result[1] = result[0].setStatus(
      ErrorMsg(msg).error.msg.splitLines[0], isError = true)

  elif msg of ClearStatusMsg:
    result[0].status = ""
    result[0].statusIsError = false

  elif msg of PasteMsg:
    # The filter is the only thing here that takes text, so a paste anywhere
    # else is not for us. `TextInput.handle` is `handleKey` widened to take one.
    if m.mode == mFilter and result[0].filter.handle(msg):
      result[0].refilter()
      result[1] = result[0].scheduleDiff()

  elif msg of MouseMsg:
    result[1] = result[0].onMouse(MouseMsg(msg))

  elif msg of KeyMsg:
    result[1] = result[0].onKey(KeyMsg(msg))

# --- view ---------------------------------------------------------------------

proc commitsPerDay(m: Model, days: int): seq[float] =
  ## A bar per day for the last `days`, from whatever history has arrived.
  result = newSeq[float](days)
  let today = getTime().toUnix div 86_400
  for c in m.commits:
    let day = int(today - c.at div 86_400)
    if day >= 0 and day < days: result[days - 1 - day] += 1.0

proc containedLabel(m: Model): string =
  ## Which branches hold the selected commit — the half of the question that a
  ## decoration cannot answer.
  ##
  ## A decoration names the commit a branch points *at*, so `git log`'s
  ## parentheses only ever mark tips: scroll one commit past the head of a
  ## branch and there is nothing on screen that says which branch you are
  ## looking at any more. Containment is the other direction — every branch that
  ## can reach this commit — and it is what actually answers "is this fix on
  ## master yet".
  ##
  ## It is shown for the selection only, because it costs a subprocess per
  ## commit; a column of it down the list would be one `git branch --contains`
  ## per visible row per frame.
  let t = m.theme
  if m.selected.sha.len == 0: return ""
  if m.diffOf != m.selected.sha:
    # The debounce is still running, so the only honest thing to say about this
    # commit is that we have not asked yet. The alternative is to leave the
    # previous commit's answer on screen under the new commit's sha, which is
    # not a stale display but a wrong one.
    return t.mutedStyle.render("in …")
  if m.containedIn.len == 0:
    return t.mutedStyle.render("on no branch")
  var s: Spans
  s.add("in ", t.mutedStyle)
  for i, b in m.containedIn:
    if i >= MaxContain:
      s.add(&" +{m.containedIn.len - MaxContain}", t.mutedStyle)
      break
    if i > 0: s.add(", ", t.mutedStyle)
    s.add(b.name, if b.remote: t.infoStyle else: t.successStyle)
  s.render()

proc header(m: Model): string =
  let t = m.theme
  let title = gradientText(" gitlog", t.ramp, Style().bold())
  let where =
    if m.root.len == 0: t.mutedStyle.render(" opening…")
    else: "  " & t.accentStyle.render(m.root.lastPathPart) & " " &
          t.mutedStyle.render("on ") & t.secondaryStyle.render(m.branch) &
          t.mutedStyle.render(" @" & m.head)
  let state =
    if m.loading and m.animate: t.accentStyle.render(spinner(m.frame) & " loading")
    elif m.loading: t.mutedStyle.render("… loading")
    elif m.loadedAll: t.mutedStyle.render($m.commits.len & " commits")
    else: ""
  let filterNote =
    if m.filter.isEmpty: ""
    else: t.warnStyle.render(&"filter {m.filtered.len}/{m.commits.len}  ")

  # The containment answer goes in the centre segment, which `statusBar` drops
  # first when the three cannot all fit — the right degradation for it, since it
  # is the one of the three that is an annotation rather than a location.
  let bar = statusBar(title & where, m.containedLabel,
                      filterNote & state & " ", m.size.width)

  # Second row: the shape of the history, and what the terminal said about
  # itself — the one place `ckDefault` is worth showing, since a palette that
  # silently fell back looks exactly like one that did not.
  let spark = sparkline(m.commitsPerDay(min(max(m.size.width - 34, 8), 60)),
                        min(max(m.size.width - 34, 8), 60), t.ramp)
  let bgNote =
    if m.bg.kind == ckDefault: t.mutedStyle.render("bg: unknown")
    else: t.mutedStyle.render("bg: " & (if m.bg.luminance < 0.5: "dark" else: "light"))
  bar & "\n" & statusBar(" " & t.mutedStyle.render("30d ") & spark, "",
                         bgNote & " ", m.size.width)

proc refChips(refs: string, t: Theme, budget: int, plain = false): (string, int) =
  ## `%D` as a row of coloured chips, and the columns they cost.
  ##
  ## This is the thing `git log` shows in parentheses after the sha, and it is
  ## half the answer to "which branch is this commit on": a decoration says a
  ## ref points *at* this commit, which is exactly what a branch tip is.
  ##
  ## The kind of each ref is carried by a one-column prefix rather than by its
  ## colour alone — `*` for the checked-out branch, `#` for a tag, and the
  ## `remote/` name a remote-tracking branch already has. Colour is the thing
  ## this library will drop first (`NO_COLOR`, `cpAnsi16`, a user's remapped
  ## palette), and a decoration that says *branch or tag* only in colour says
  ## nothing at all on the terminals most likely to be reading it.
  ##
  ## The width is returned rather than measured by the caller because the
  ## chips are styled: `displayWidth` would be right and would also be a second
  ## walk over a string this proc has just built one rune at a time.
  ##
  ## `plain` is the selected row, and it drops every colour — but not the bold,
  ## which is an attribute and reads on any background — rather than picking
  ## different colours. A chip carries a foreground and nothing else, so on the
  ## selection it is drawn *over the selection's background* — and the branch
  ## chip's colour is `accent`, which is the selection background: the branch
  ## the reader is most likely to be looking for disappears on exactly the row
  ## they moved the cursor to. Colouring it against the selection instead means
  ## a second palette that has to stay legible on one specific background,
  ## where the prefixes already say what each ref is. This is the `NO_COLOR`
  ## argument above, arriving from the other side.
  if refs.len == 0 or budget <= 0: return ("", 0)
  template styled(s: Style): Style = (if plain: Style() else: s)
  var
    chips: Spans
    w = 0
    dropped = 0
    first = ""                        # the first chip that would not fit
    firstStyle = Style()
  let items = refs.split(", ")
  for i, item in items:
    var
      name = item.strip
      style = styled(t.successStyle)  # a local branch
    if name.startsWith("tag: "):
      name = "#" & name["tag: ".len .. ^1]
      style = styled(t.warnStyle)
    elif name.startsWith("HEAD -> "):
      name = "*" & name["HEAD -> ".len .. ^1]
      style = styled(t.accentStyle).bold
    elif name == "HEAD":              # detached, and worth saying so
      name = "*HEAD"
      style = styled(t.accentStyle).bold
    elif '/' in name:
      style = styled(t.infoStyle)     # remote-tracking
    let cost = displayWidth(name) + (if w == 0: 0 else: 1)
    # A chip is cut whole or not at all: half a branch name is a branch name
    # that is not this one. The exception is the *first* one, below, and it is
    # an exception because "some ref points here" is worth a column even when
    # naming it is not affordable.
    #
    # And what does not fit stops the row rather than being skipped over: `%D`
    # arrives in git's own order, HEAD first, so a later chip squeezing into
    # the gap an earlier one could not fill means the row names the *least*
    # important ref pointing at the commit and hides the one that is checked
    # out. A count is the better answer to "there is more than this".
    if w + cost > budget:
      if w == 0: first = name; firstStyle = style
      dropped = items.len - i
      break
    if w > 0: chips.add(" ", Style())
    chips.add(name, style)
    w += cost
  if w == 0 and first.len > 0 and budget >= MinChip:
    # The commit list is a third of a narrow screen, so this is not a corner
    # case: at 100 columns the rows are 36 wide and no branch name fits beside
    # a subject. An elided chip still says a ref points at this commit, which
    # is the thing being scrolled past that must not be invisible — and `elide`
    # marks the cut, where a silently shortened name would read as a shorter
    # branch that does exist. The header names it in full either way.
    let cut = elide(first, budget)
    chips.add(cut, firstStyle)
    w = displayWidth(cut)
    dropped.dec
  if dropped > 0:
    # What is left over is a count, which at three columns is all there is room
    # for and is still the difference between "no refs here" and "some".
    let note = (if w > 0: " " else: "") & "+" & $dropped
    if w + note.len <= budget:
      chips.add(note, styled(t.mutedStyle))
      w += note.len
  (chips.render(), w)

proc commitLine(m: Model, idx, width: int, selected = false): string =
  let
    t = m.theme
    c = m.commits[m.filtered[idx]]
    date = fromUnix(c.at).local.format("MM-dd")
    author = elide(c.author, 12)
    meta = date & " " & author
    # What is left once the sha, the metadata and a readable minimum of subject
    # have been paid for. Decorations are an annotation on the row: they may eat
    # the slack, never the line.
    budget = min(max(width - displayWidth(meta) - 10 - MinSubject, 0), MaxChips)
    (chips, chipsW) = refChips(c.refs, t, budget, plain = selected)
    room = max(width - displayWidth(meta) - 10 - (if chipsW > 0: chipsW + 1 else: 0), 6)
  var line: Spans
  line.add(c.short & " ", t.secondaryStyle)
  if chipsW > 0: line.add(chips & " ", Style())
  line.add(padVisible(elide(c.subject, room), room) & " ", Style())
  line.add(meta, t.mutedStyle)
  line.render()

proc commitsPane(m: Model, r: Rect): string =
  let t = m.theme
  let inner = r.inner
  # Only the window is built — not one string per commit.
  #
  # This is the seam where "the component does not own the data" stops being
  # free, and it is worth spelling out because the obvious spelling is a
  # `seq[string]` as long as the history. `ListView.render` indexes from
  # `vp.top` and sizes its scrollbar from `items.len`, so it wants the whole
  # list; on a repository with a hundred thousand commits that is a hundred
  # thousand strings allocated every frame to draw thirty of them, and the cost
  # arrives exactly when the paged loading above has finished being impressive.
  #
  # So the window is drawn against a local view whose top is zero, with the
  # gutter left off, and the *real* viewport puts the scrollbar on afterwards —
  # which is the one part that has to know the true total.
  var win = ListView(vp: Viewport(top: 0, height: inner.h),
                     cursor: m.list.cursor - m.list.vp.top)
  var items = newSeqOfCap[string](inner.h)
  for i in m.list.vp.top ..< min(m.list.vp.top + inner.h, m.filtered.len):
    items.add m.commitLine(i, inner.w - 2, selected = i == m.list.cursor)
  let body =
    if m.filtered.len == 0 or inner.w <= 1:
      padBlock(t.mutedStyle.render("  no commits match"), inner.w, inner.h)
    else:
      m.list.vp.withScrollbar(
        win.render(items, inner.w - 1, selectedStyle = t.selectionStyle,
                   showScrollbar = false).split('\n'),
        m.filtered.len, t.mutedStyle).join("\n")
  panel(RoundedBorder)
    .title(" commits ")
    .footer(if m.filtered.len == 0: " 0 "
            else: &" {m.list.cursor + 1}/{m.filtered.len} ")
    .styled(border = t.borderStyleFor(m.focus == pCommits),
            title = t.titleStyle, footer = t.mutedStyle)
    .render(body, r.w, r.h)

proc churn(f: FileStat, width: int, t: Theme): string =
  ## A bar split between what the file gained and what it lost, at one glyph per
  ## line of change but never wider than the column.
  if f.binary: return t.warnStyle.render("binary")
  let total = f.added + f.removed
  if total == 0 or width <= 0: return ""
  let cells = min(total, width)
  let plus = int(round(f.added / total * cells.float))
  var s: Spans
  s.add("▰".repeat(plus), Style().fg(t.success))
  s.add("▰".repeat(cells - plus), Style().fg(t.error))
  s.render()

proc filesPane(m: Model, r: Rect): string =
  let t = m.theme
  let inner = r.inner
  var tbl = table([column("file", minWidth = 8),
                   column("+", align = aRight, minWidth = 3),
                   column("−", align = aRight, minWidth = 3),
                   column("churn", width = max(inner.w div 5, 6))],
                  border = HiddenBorder)
  tbl.showBorder = false         # no frame, and no rules between the columns
  tbl.columnRules = false        # either — they are two switches, not one
  tbl.headerRule = false         # the rule under a hidden border is a blank row
  tbl.padding = 1
  for f in m.files:
    tbl.add(f.path,
            if f.binary: "·" else: t.successStyle.render($f.added),
            if f.binary: "·" else: t.errorStyle.render($f.removed),
            f.churn(max(inner.w div 5, 6), t))
  let body =
    if m.files.len == 0: t.mutedStyle.render("  no files")
    else: tbl.render(inner.w)
  panel(RoundedBorder)
    .title(" files ")
    .footer(if m.files.len == 0: "" else: &" {m.files.len} ")
    .styled(border = t.borderStyle, title = t.titleStyle, footer = t.mutedStyle)
    .render(body, r.w, r.h)

proc diffPane(m: Model, r: Rect): string =
  let t = m.theme
  let
    c = m.selected
    title = if c.sha.len == 0: " diff "
            else: " " & c.short & "  " & elide(c.subject, max(r.w - 20, 8)) & " "
    source = if m.gitColour: "git" else: "bg-mixed"
  panel(RoundedBorder)
    .title(title)
    .footer(" " & m.diff.positionLabel & "  " & source & " ")
    .styled(border = t.borderStyleFor(m.focus == pDiff),
            title = t.titleStyle, footer = t.mutedStyle)
    .render(m.diff.render(), r.w, r.h)

proc helpOverlay(m: Model): string =
  let t = m.theme
  const rows = [
    ("j / k, ↑ ↓", "move (the focused pane's own keys)"),
    ("tab", "move focus between commits and diff"),
    ("/", "filter by subject, author, ref or sha"),
    ("enter, o", "git show, on the terminal, in git's pager"),
    ("E", "$EDITOR on the first file the commit touched"),
    ("c", "colour the patch here, or let git do it"),
    ("*name", "a branch tip; #name a tag"),
    ("header", "the branches that contain the selection"),
    ("h / l, ← →", "scroll the diff sideways"),
    ("0 / $", "the far left of the diff, and the far right"),
    ("r", "reload the history"),
    ("ctrl+z", "suspend"),
    ("q", "quit")]
  var body: seq[string]
  for (k, d) in rows:
    body.add "  " & t.accentStyle.render(padVisible(k, 12)) & " " &
             t.mutedStyle.render(d)
  panel(DoubleBorder)
    .title(" keys ")
    .pad(1)
    .shadow(t.mutedStyle)
    .styled(border = t.activeBorderStyle, title = t.titleStyle)
    .render(body.join("\n"), 62, body.len + 4)

proc footer(m: Model): string =
  let t = m.theme
  if m.mode == mFilter:
    return " " & t.accentStyle.render("/") &
           m.filter.render(max(m.size.width - 3, 4))
  if m.status.len > 0:
    return " " & (if m.statusIsError: t.errorStyle.render("✗ " & m.status)
                  else: t.mutedStyle.render(m.status))
  " " & hints({"j/k": "move", "h/l": "sideways", "tab": "focus",
               "/": "filter", "enter": "show",
               "c": "colour", "?": "keys", "q": "quit"})

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let r = m.regions
  var left = m.commitsPane(r.commits)
  if r.files.w > 0: left = joinVertical(left, m.filesPane(r.files))
  let body =
    if r.diff.w > 0: joinHorizontal([left, m.diffPane(r.diff)])
    else: left
  let frame = joinVertical(m.header, body, m.footer)
  if m.mode == mHelp: place(frame, m.helpOverlay) else: frame

# --- headless self-test -------------------------------------------------------

proc selfTest() =
  ## The whole update proc, with no terminal and no repository.
  ##
  ## Nothing here shells out: the tests that would need git call `update`
  ## directly with the message a command *would* have produced, which is the
  ## point of `update` being an ordinary pure function. The one thing that does
  ## reach the runtime is `execCmd`, and `runHeadless` deliberately runs no
  ## child — it calls `then` with an error instead, so a state machine waiting
  ## on one carries on rather than stalling. That behaviour is documented and
  ## otherwise untested.
  proc fixture(n: int): Model =
    result = Model(root: "/tmp/repo", branch: "main", head: "abc1234",
                   theme: DefaultTheme, animate: true, gen: 1)
    result.list = initListView(height = 10)
    result.diff = initTextArea(width = 40, height = 10, wrap = false)
    result.filter = initTextInput(placeholder = "filter")
    result.size = TermSize(width: 120, height: 40)
    for i in 0 ..< n:
      result.commits.add Commit(sha: &"{i:040x}", short: &"{i:07x}",
                                author: (if i mod 2 == 0: "ada" else: "grace"),
                                at: getTime().toUnix - i.int64 * 3600,
                                subject: (if i mod 3 == 0: "fix the thing "
                                          else: "add a thing ") & $i)
    result.refilter()

  # Parsing is the boundary everything else rests on, and git's field separator
  # is chosen so a subject containing one cannot break it.
  let parsed = parseCommits(
    "deadbeef\x1fdeadbee\x1fada\x1f1700000000\x1fHEAD -> main, tag: v1\x1f" &
    "subject with\ta tab")
  doAssert parsed.len == 1
  doAssert parsed[0].author == "ada"
  doAssert parsed[0].subject == "subject with\ta tab"
  doAssert parsed[0].at == 1_700_000_000
  doAssert parsed[0].refs == "HEAD -> main, tag: v1"
  # An undecorated commit is the overwhelming majority, and its record has an
  # empty field rather than a missing one — the trailing subject still parses.
  let bare = parseCommits("deadbeef\x1fdeadbee\x1fada\x1f1700000000\x1f\x1fplain")
  doAssert bare.len == 1 and bare[0].refs == "" and bare[0].subject == "plain"
  echo "ok — a log record survives a subject containing a separator-ish byte"

  # The two halves of the branch question, which are different questions.
  # Decorations say what points *at* a commit ...
  let t = DefaultTheme
  let (chips, chipsW) = refChips("HEAD -> main, origin/main, tag: v1", t, 40)
  doAssert displayWidth(chips) == chipsW, "the width returned is the width drawn"
  doAssert "*main" in chips and "#v1" in chips and "origin/main" in chips,
    "the kind of a ref survives without colour"
  let (cut, cutW) = refChips("HEAD -> main, origin/main, tag: v1", t, 8)
  doAssert cutW <= 8, "decorations may eat the slack, never the line"
  doAssert "*main" in cut and "origin/main" notin cut,
    "a chip is cut whole or not at all"
  doAssert refChips("", t, 40)[1] == 0
  # On the selected row the chips carry no colour of their own. A chip sets a
  # foreground only, so it is drawn over the selection's background — and the
  # branch chip's colour *is* that background, which makes the branch name
  # vanish on the one row the cursor is on. Bytes rather than dimensions,
  # because nothing about the width of this is wrong.
  let (onSel, onSelW) = refChips("HEAD -> main, tag: v1", t, 40, plain = true)
  doAssert "38;2;" notin onSel and "38;5;" notin onSel,
    "the selection's own foreground has to reach the chips"
  doAssert "\e[1m" in onSel, "bold is not a colour, and still marks the checked-out branch"
  doAssert onSelW == displayWidth(onSel)
  doAssert "*main" in onSel and "#v1" in onSel, "and the prefixes still say which is which"
  echo "ok — decorations are cut to a budget, whole chips at a time"

  # ... and containment says what can *reach* it, which is the half `git log`
  # cannot show and the reason a commit ten back from a tip is not anonymous.
  let held = parseBranches(
    "refs/heads/main\nrefs/remotes/origin/main\nrefs/remotes/origin/HEAD\n" &
    "refs/heads/feature/x\nrefs/tags/v1\n")
  doAssert held.len == 3, "a tag is not a branch, and origin/HEAD is a duplicate"
  doAssert not held[0].remote and not held[1].remote,
    "local branches come first, since only the first few are shown"
  doAssert held[0].name == "main" and held[1].name == "feature/x"
  doAssert held[2].name == "origin/main" and held[2].remote
  echo "ok — containment lists the branches that hold a commit, mine first"

  # And the load that answers it is the debounced one, so holding `j` runs no
  # more of these than it runs `git show`.
  var b = fixture(3)
  b.list.moveTo(0, b.filtered.len)
  (b, _) = update(b, DiffMsg(gen: b.diffGen, sha: b.selected.sha,
                             patch: "@@ -1 +1 @@\n+x\n", numstat: "",
                             branches: "refs/heads/main\n"))
  doAssert b.containedIn.len == 1 and b.containedIn[0].name == "main"
  doAssert "main" in b.containedLabel
  b.list.moveTo(1, b.filtered.len)
  doAssert "…" in b.containedLabel,
    "a commit whose answer has not arrived must not wear the previous one\'s"
  # An answer of "nothing" is an answer, and a common one: a commit reachable
  # only from a tag, or from a remote head with no branch on it.
  (b, _) = update(b, DiffMsg(gen: b.diffGen, sha: b.selected.sha,
                             patch: "", numstat: "", branches: ""))
  doAssert "no branch" in b.containedLabel
  echo "ok — the containment answer belongs to the commit it was asked about"

  let stats = parseNumstat("12\t3\tsrc/a.nim\n-\t-\tlogo.png\n")
  doAssert stats.len == 2
  doAssert stats[0].added == 12 and stats[0].removed == 3
  doAssert stats[1].binary, "a binary file is not zero lines changed"
  doAssert stats[1].added == 0
  echo "ok — a binary file is distinguishable from an empty change"

  # The generation guard, which is what stops a superseded load: a stale page
  # must neither append nor issue its successor.
  var m = fixture(PageSize)
  m.gen = 4
  let stalePage = PageMsg(gen: 3, skip: 0, commits: @[Commit(sha: "x")])
  let (afterStale, staleCmd) = update(m, stalePage)
  doAssert afterStale.commits.len == PageSize, "a stale page must not append"
  doAssert staleCmd == nil, "a stale page must not issue the next one, or the chain lives on"

  let freshPage = PageMsg(gen: 4, skip: PageSize,
                          commits: newSeq[Commit](PageSize))
  let (afterFresh, freshCmd) = update(m, freshPage)
  doAssert afterFresh.commits.len == 2 * PageSize
  doAssert freshCmd != nil, "a full page means there may be more"

  let (afterShort, shortCmd) = update(m, PageMsg(gen: 4, skip: PageSize,
                                                 commits: @[Commit(sha: "y")]))
  doAssert afterShort.loadedAll, "a short page is the end of the history"
  doAssert shortCmd == nil
  echo "ok — a page from a superseded load does nothing and starts no successor"

  # Filtering, and the cursor it leaves behind. This is the crash rather than a
  # cosmetic fault: a cursor past the end of the filtered list is read on the
  # very next frame.
  var f = fixture(30)
  f.list.moveTo(27, f.filtered.len)
  f.filter.text = "fix"
  f.refilter()
  doAssert f.filtered.len == 10, &"expected 10 matches, got {f.filtered.len}"
  doAssert f.list.cursor < f.filtered.len, "the cursor must still point at something"
  doAssert f.selected.subject.startsWith("fix")
  echo "ok — filtering narrows the list and drags the cursor back into it"

  # The debounce, which is a property of the second generation counter: moving
  # again before the timer fires must invalidate the earlier load.
  var d = fixture(30)
  discard d.scheduleDiff()                 # arms one for commit 0
  let armed = d.diffGen
  d.list.moveTo(5, d.filtered.len)
  discard d.scheduleDiff()                 # the selection moved first
  let (afterLate, lateCmd) = update(d, DiffLoadMsg(gen: armed, sha: "whatever"))
  doAssert lateCmd == nil, "a debounce timer for a selection we have left must not load"
  doAssert afterLate.diffOf.len == 0
  let (_, liveCmd) = update(d, DiffLoadMsg(gen: d.diffGen, sha: d.selected.sha))
  doAssert liveCmd != nil, "the current one still loads"
  echo "ok — a superseded debounce timer loads nothing"

  # Key dispatch: the filter field has to be able to swallow `q`, and the pane
  # underneath has to get it back the moment the field is closed.
  var k = fixture(10)
  k.mode = mFilter
  discard k.onKey(KeyMsg(key: kRune, rune: "q".runeAt(0)))
  doAssert k.filter.text == "q", "a text field swallows `q`"
  k.mode = mBrowse
  let quitting = k.onKey(KeyMsg(key: kRune, rune: "q".runeAt(0)))
  doAssert quitting != nil and quitting() of QuitMsg, "and gives it back when closed"
  echo "ok — the same key is text in one mode and a command in the other"

  # `ckDefault` is the normal answer, and the fallback has to be a design.
  var bg = fixture(1)
  bg.applyBackground Color()
  doAssert bg.addStyle.bgc.kind == ckDefault,
    "with no answer there is nothing to mix against, so no backgrounds"
  doAssert bg.addStyle.fgc.kind != ckDefault, "the sign has to survive somewhere"
  bg.applyBackground hex"#0d1117"
  doAssert bg.addStyle.bgc.kind != ckDefault, "with an answer, a mixed background"
  doAssert bg.theme.fg.luminance > 0.5, "a dark terminal wants light text"
  bg.applyBackground hex"#fbfbfb"
  doAssert bg.theme.fg.luminance < 0.5, "and a light one wants dark"
  echo "ok — the palette follows the terminal, and copes when it will not say"

  # `h` / `l` scroll the diff sideways, and stop where the content does. The
  # bound is the half that can only be got wrong in one direction: without it
  # `l` slides the pane off into blank, which looks exactly like a broken
  # render. The patch is coloured here, so `longest` is also the assertion that
  # the width is measured in columns rather than in bytes.
  var x = fixture(3)
  x.relayout()
  x.focus = pDiff
  let long = "-let x = " & "y".repeat(400)
  (x, _) = update(x, DiffMsg(gen: x.diffGen, sha: "abc1234",
                             patch: "@@ -1 +1 @@\n" & long & "\n",
                             numstat: ""))
  doAssert x.longest == displayWidth(long), "escapes cost no columns"
  doAssert x.maxX > 0, "a patch line runs past the pane"
  let l = KeyMsg(key: kRune, rune: "l".runeAt(0))
  let h = KeyMsg(key: kRune, rune: "h".runeAt(0))
  discard x.onKey(l)
  doAssert x.diff.xOffset == 1
  discard x.onKey(h)
  doAssert x.diff.xOffset == 0
  discard x.onKey(h)
  doAssert x.diff.xOffset == 0, "and stops at column zero"
  for _ in 0 .. x.maxX + 20: discard x.onKey(l)
  doAssert x.diff.xOffset == x.maxX, "and at the longest line"
  for line in x.diff.render().split('\n'):
    doAssert displayWidth(line) == x.diff.width, "a scrolled pane keeps its width"
  # `0` and `$` land on those same two ends in one keypress, from anywhere.
  let zero = KeyMsg(key: kRune, rune: "0".runeAt(0))
  let dollar = KeyMsg(key: kRune, rune: "$".runeAt(0))
  discard x.onKey(zero)
  doAssert x.diff.xOffset == 0, "0 goes all the way left"
  discard x.onKey(dollar)
  doAssert x.diff.xOffset == x.maxX, "$ goes as far right as there is anything"
  discard x.onKey(l)
  doAssert x.diff.xOffset == x.maxX, "and there is nothing past it"
  for line in x.diff.render().split('\n'):
    doAssert displayWidth(line) == x.diff.width, "a scrolled pane keeps its width"
  echo "ok — h/l/0/$ scroll the diff sideways and stop where the content does"

  # `execCmd` through the real loop, with no terminal: no child is run and
  # `then` is called with an error, which is what keeps this from stalling.
  #
  # `maxTimers = 0` is load-bearing and is the trap worth writing down: headless
  # timers are delivered *immediately*, in scheduled order, so the four-second
  # `ClearStatusMsg` that `setStatus` arms fires before the run ends and wipes
  # the very thing being asserted. A duration is a deadline to the real loop and
  # only an ordering to this one.
  var e = fixture(3)
  e.animate = false
  let final = newProgram(e, update, view).runHeadless(@[
    Msg(KeyMsg(key: kEnter))], maxTimers = 0)
  doAssert final.statusIsError, "headless exec reports why it did not run"
  doAssert final.status.len > 0
  echo "ok — execCmd under runHeadless answers instead of hanging"

  echo "all good"

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--selftest":
    selfTest()
    quit(0)

  let path = if paramCount() > 0: paramStr(1).absolutePath else: getCurrentDir()
  var model = Model(theme: DefaultTheme, loading: true, animate: true, gen: 1)
  model.list = initListView(height = 10, wrapAround = false)
  model.diff = initTextArea(width = 40, height = 10, wrap = false)
  model.filter = initTextInput(placeholder = "subject, author, ref or sha")
  model.applyBackground Color()      # until the terminal says otherwise

  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor, poMouseClicks,
                                poBracketedPaste, poFocusReporting,
                                poQueryBackground},
                     initCmd = batch(repoCmd(path), spinCmd())).run()
