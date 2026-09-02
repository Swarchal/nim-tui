## **A highlighted snippet is a card, and a card is where the fragment problem
## lives.**
##
## Neither half of this is about scrolling a file, which is what the library's
## own `codeview` example is for.
##
## The first half is that a highlighted line is an *ordinary* `Spans`. `Panel`
## frames it, sizes the border to it and pads it out knowing nothing about a
## grammar: the escape sequences cost no columns, so the box that fits the text
## is the box that fits the code. The card is therefore measured from the
## snippet rather than cut from the screen — the shape a code sample wants, and
## the one thing a full-screen viewer never has to get right.
##
## The second is `Options.maxErrorRatio`, which exists for exactly this: an
## excerpt is what goes in a box, tree-sitter recovers from malformed input, and
## a fragment pulled out of context parses into `ERROR` nodes and comes back out
## as *confidently wrong* colours. `f` turns the guard on and the footer prints
## the ratio the parse produced, because the useful thing here is not that a
## knob exists but what the number does — and it is not what the name suggests:
##
## | snippet | grammar | ratio |
## | --- | --- | --- |
## | the whole function | python | 0.00 |
## | the `elif` branch alone | python | 0.05 |
## | a *traceback*, as python | python | 0.12 |
## | English prose, as python | python | 0.11 |
## | that same python, as json | json | 0.62 |
##
## So the ratio measures how permissive the *grammar* is, not how broken the
## text is. Python's is loose enough to find expressions in prose, which is why
## every python row sits near the floor and 0.3 never fires on one; json's is
## strict, so it crosses immediately. `maxErrorRatio` catches **this is not that
## language** — the case a card actually hits, since a snippet arrives with its
## language guessed rather than known. It does not catch *this stopped halfway*,
## and no threshold that did would leave a truncated excerpt coloured.
##
##   nimble snippets

import std/[strutils, strformat]
import nimtui
import treesitter
import treesitter/adapters/tui
import treesitter/langs/[python, json]

const
  TabWidth = 4
  Guard = 0.3
    ## The library's own suggestion for excerpts. Its default is 1.0 — never bail
    ## — because a whole file should stay coloured whatever its parse looked like.

type
  Snippet = object
    label, lang, code: string

  Card = object
    ## What `reload` works out once per snippet. Note what is *not* here: the
    ## `Tree`. It is not copyable and the runtime treats a model as a value, so
    ## the ratio is taken at load and the tree is dropped.
    label, lang: string
    source: string
    ratio: float
    hl: Highlights
    styles: seq[nimtui.Style]
      ## Per card, not per model: a capture id is an index into *this* grammar's
      ## query, so one resolved seq shared between python and json would colour
      ## one of them by the other's numbering — same width, wrong picture.
    fellBack: bool

  Model = object
    cards: seq[Card]
    sel: int
    guard: bool
    size: TermSize
    theme: nimtui.Theme

const Snippets = @[
  Snippet(label: "a whole file", lang: "python", code: """
def tokens(src):
    depth = 0
    for i, ch in enumerate(src):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            assert depth >= 0, f"unbalanced at {i}"
    return depth
"""),
  Snippet(label: "a whole file", lang: "json", code: """
{
  "name": "nimtui",
  "version": "0.4.0",
  "options": { "altScreen": true, "mouse": null },
  "widths": [8, 16, 32]
}
"""),
  Snippet(label: "an excerpt", lang: "python", code: """
        elif node.kind == "string":
            return quote(node.text)
        else:
            raise ValueError(node.kind)
"""),
  Snippet(label: "wrong language", lang: "json", code: """
def tokens(src):
    depth = 0
    return depth
"""),
]

# --- loading ------------------------------------------------------------------

proc reload(m: var Model) =
  ## Re-parses every snippet under the current guard. That is the toggle's whole
  ## effect, and doing it here rather than in `view` is what keeps `view` a pure
  ## function of the model.
  m.cards.setLen 0
  var opts = defaultOptions()
  if m.guard: opts.maxErrorRatio = Guard

  for s in Snippets:
    var c = Card(label: s.label, lang: s.lang,
                 source: s.code.strip(leading = false))
    let lang = findLanguage(s.lang)
    if lang == nil:
      # No grammar is a normal outcome, not an error: the text line-splits
      # through the same path and renders plain.
      c.hl = plainHighlights(c.source)
    else:
      # A parse of its own, because `highlight` does not hand the tree back —
      # and the number is the point of the footer.
      c.ratio = initParser(lang.lang).parse(c.source).errorRatio
      c.fellBack = m.guard and c.ratio > Guard
      c.hl = newHighlighter(lang).highlight(c.source, opts)
      c.styles = defaultSyntaxStyles().compile(c.hl.captureNames)
    m.cards.add c

# --- the card -----------------------------------------------------------------

proc codeBlock(m: Model, c: Card, inner: int): (string, int) =
  ## The snippet as a block, plus the width it wanted. Every line goes through
  ## the adapter's `toSpans` — the library's own path, tabs expanded there
  ## because `Spans.add` would flatten one to a single space — and comes back a
  ## `Spans` that `fit` treats like any other line.
  var
    lines: seq[string]
    wanted = 0
  for i in 0 ..< c.hl.lineCount:
    let s = toSpans(c.source, c.hl, i, c.styles, tabWidth = TabWidth)
    wanted = max(wanted, s.displayWidth)
    lines.add s.fit(inner).render()
  (lines.join("\n"), wanted)

proc card(m: Model, c: Card, avail: int): string =
  let
    t = m.theme
    pad = 1
    # Two passes, because the box is sized to the code rather than the other way
    # round: measure at the widest the screen allows, then draw at what the code
    # asked for. The measuring pass is free of the escapes — `displayWidth` skips
    # them — which is the whole reason a coloured line can be laid out at all.
    room = max(avail - 2 * pad - 2, 1)
    inner = min(m.codeBlock(c, room)[1], room)
    body = m.codeBlock(c, inner)[0]

  let
    title = c.lang & " · " & c.label
    footer =
      if c.fellBack: t.warnStyle.render(&"plain · {c.ratio:.2f} > {Guard:.2f}")
      else: t.mutedStyle.render(&"ratio {c.ratio:.2f}")
    # A box sized to its content still has to be wide enough for its own labels,
    # or `borderRow` elides them: it spaces a label off the border on both sides
    # and truncates it to the interior less four, so a label fits when the outer
    # width is at least six past it. Measured with `displayWidth` rather than
    # `len`, since the footer arrives already styled and its escapes are not
    # columns.
    labelled = max(displayWidth(title), displayWidth(footer)) + 6
    width = min(max(inner + 2 * pad + 2, labelled), avail)

  panel(RoundedBorder)
    .border(if c.fellBack: HeavyDashedBorder else: RoundedBorder)
    .title(title)
    .footer(footer)
    .pad(pad)
    .styled(border = if c.fellBack: t.warnStyle else: t.borderStyle,
            title = t.titleStyle)
    .render(body, width, c.hl.lineCount + 2 * pad + 2)

# --- update -------------------------------------------------------------------

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)
  discard result[0].size.handleResize(msg)

  if msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "esc", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("tab", "right", "l"):
      result[0].sel = (m.sel + 1) mod m.cards.len
    elif k.matches("shift+tab", "left", "h"):
      result[0].sel = (m.sel + m.cards.len - 1) mod m.cards.len
    elif k.matches("f"):
      result[0].guard = not m.guard
      result[0].reload()

# --- view ---------------------------------------------------------------------

proc view(m: Model): string =
  if m.size.width == 0: return "loading…"
  let
    t = m.theme
    c = m.cards[m.sel]
    box = m.card(c, min(m.size.width - 8, 72))
    bw = blockWidth(box)

  var dots: Spans
  for i in 0 ..< m.cards.len:
    dots.add(if i == m.sel: "● " else: "○ ",
             if i == m.sel: t.accentStyle else: t.mutedStyle)

  let guardLine =
    if m.guard: t.accentStyle.render(&"fragment guard on ({Guard:.2f})")
    else: t.mutedStyle.render("fragment guard off")

  let stack = joinVertical(box, "", centerVisible(dots.render(), bw), "",
                           centerVisible(guardLine, bw))

  place(padBlock("", m.size.width, m.size.height - 1), stack) & "\n" &
    hints({"tab/←→": "snippet", "f": "guard", "q": "quit"})

when isMainModule:
  var m = Model(theme: DefaultTheme, guard: true)
  m.reload()
  discard newProgram(m, update, view,
                     options = {poAltScreen, poHideCursor}).run()
