## Box-drawing glyphs as an algebra rather than a list.
##
## A junction is four arms — top, right, bottom, left — each of which is absent
## or drawn at one of three weights. That is a `Quad`, and `boxChar` turns one
## into the glyph. There is no arithmetic relationship between these codepoints,
## so the mapping has to be a table; what the table buys is that junctions can
## then be *computed*, including the ones nobody enumerated:
##
## ```nim
## echo boxChar(quad(lwThin, lwThin, lwThin, lwThin))     # ┼
## echo boxChar(quad(lwDouble, lwThin, lwDouble, lwThin)) # ╫ — a thin rule
##                                                        #     crossing a
##                                                        #     double frame
## echo combine(quad(right = lwThin, left = lwThin),      # ─ over │
##              quad(top = lwThin, bottom = lwThin))      # -> ┼
## ```
##
## `layout.ruledBorder <layout.html#ruledBorder,LineWeight,LineWeight>`_ is the
## reason this exists: it builds a whole `Border` — corners, edges and all five
## junctions — out of a frame weight and a rule weight, so a border whose
## interior rules are lighter than its frame is a call rather than eleven glyphs
## looked up by hand.
##
## No dependencies, and none wanted: this is a lookup table and four accessors,
## and it sits at the bottom of the stack beside `nimtui/width <width.html>`_.
##
## **Only 110 of the 256 quads exist.** A glyph carries at most two weights, and
## the double-line set is thinner still — there is no `═` meeting `━`, and
## nothing with three weights in it at all. The rest degrade down a fixed ladder
## ending at all-thin, which is complete, so `boxChar` always returns a real
## single-column glyph and never a fallback marker. Degrading rather than
## failing is the right answer for a drawing primitive, but it does mean two
## different quads can come back as the same glyph: `boxChar` is not injective
## and nothing may assume a round trip.
##
## The table is generated from the Unicode names, not typed. The Box Drawing
## block encodes the structure exactly — `BOX DRAWINGS VERTICAL DOUBLE AND
## HORIZONTAL SINGLE` is `(double, thin, double, thin)` — so it is parsed out,
## which is what makes 256 entries trustworthy. The `static:` block below
## re-checks the properties that a bad table would break, in the spirit of
## `width.nim`'s assertions on its range tables: a mistyped entry there quietly
## makes a binary search miss, and a mistyped entry here quietly draws a
## different picture at exactly the right size.

type
  LineWeight* = enum
    ## How heavily an arm is drawn. `lwNone` is no arm at all, which is what
    ## makes a corner a corner.
    lwNone
    lwThin
    lwHeavy
    lwDouble

  Quad* = object
    ## The four arms of one cell, clockwise from the top.
    top*, right*, bottom*, left*: LineWeight

func quad*(top = lwNone, right = lwNone, bottom = lwNone,
           left = lwNone): Quad =
  ## A `Quad` from named arms. Named rather than positional because four
  ## same-typed parameters in a row is the transposition this codebase avoids
  ## elsewhere — `quad(lwThin, lwNone, lwNone, lwThin)` and its transpose are
  ## both corners, and both compile.
  Quad(top: top, right: right, bottom: bottom, left: left)

func combine*(a, b: Quad): Quad =
  ## `a` with `b`'s arms laid over it, per arm — `lwNone` in `b` leaves `a`'s.
  ##
  ## This is what makes drawing a grid a matter of drawing lines: a horizontal
  ## and a vertical run over the same cell combine to the junction, and the
  ## caller never has to know which glyph that is or which lines it has already
  ## crossed.
  Quad(top: (if b.top == lwNone: a.top else: b.top),
       right: (if b.right == lwNone: a.right else: b.right),
       bottom: (if b.bottom == lwNone: a.bottom else: b.bottom),
       left: (if b.left == lwNone: a.left else: b.left))

func index(q: Quad): int =
  ord(q.top) shl 6 or ord(q.right) shl 4 or ord(q.bottom) shl 2 or ord(q.left)

const
  # Generated; see the module doc. Each row is the four values of `left` for one
  # (top, right, bottom); the trailing marks are `.` where Unicode has the glyph
  # and `*` where the entry is the nearest weight it does have.
  BoxChars: array[256, string] = [
    # top none   right none  
    " ", "╴", "╸", "╸",   # bottom none   ...*
    "╷", "┐", "┑", "╕",   # bottom thin   ....
    "╻", "┒", "┓", "┓",   # bottom heavy  ...*
    "╻", "╖", "┓", "╗",   # bottom double *.*.
    # top none   right thin  
    "╶", "─", "╾", "╾",   # bottom none   ...*
    "┌", "┬", "┭", "┭",   # bottom thin   ...*
    "┎", "┰", "┱", "┱",   # bottom heavy  ...*
    "╓", "╥", "┱", "┱",   # bottom double ..**
    # top none   right heavy 
    "╺", "╼", "━", "━",   # bottom none   ...*
    "┍", "┮", "┯", "┯",   # bottom thin   ...*
    "┏", "┲", "┳", "┳",   # bottom heavy  ...*
    "┏", "┲", "┳", "┳",   # bottom double ****
    # top none   right double
    "╺", "╼", "━", "═",   # bottom none   ***.
    "╒", "┮", "┯", "╤",   # bottom thin   .**.
    "┏", "┲", "┳", "┳",   # bottom heavy  ****
    "╔", "┲", "┳", "╦",   # bottom double .**.
    # top thin   right none  
    "╵", "┘", "┙", "╛",   # bottom none   ....
    "│", "┤", "┥", "╡",   # bottom thin   ....
    "╽", "┧", "┪", "┪",   # bottom heavy  ...*
    "╽", "┧", "┪", "┪",   # bottom double ****
    # top thin   right thin  
    "└", "┴", "┵", "┵",   # bottom none   ...*
    "├", "┼", "┽", "┽",   # bottom thin   ...*
    "┟", "╁", "╅", "╅",   # bottom heavy  ...*
    "┟", "╁", "╅", "╅",   # bottom double ****
    # top thin   right heavy 
    "┕", "┶", "┷", "┷",   # bottom none   ...*
    "┝", "┾", "┿", "┿",   # bottom thin   ...*
    "┢", "╆", "╈", "╈",   # bottom heavy  ...*
    "┢", "╆", "╈", "╈",   # bottom double ****
    # top thin   right double
    "╘", "┶", "┷", "╧",   # bottom none   .**.
    "╞", "┾", "┿", "╪",   # bottom thin   .**.
    "┢", "╆", "╈", "╈",   # bottom heavy  ****
    "┢", "╆", "╈", "╈",   # bottom double ****
    # top heavy  right none  
    "╹", "┚", "┛", "┛",   # bottom none   ...*
    "╿", "┦", "┩", "┩",   # bottom thin   ...*
    "┃", "┨", "┫", "┫",   # bottom heavy  ...*
    "┃", "┨", "┫", "┫",   # bottom double ****
    # top heavy  right thin  
    "┖", "┸", "┹", "┹",   # bottom none   ...*
    "┞", "╀", "╃", "╃",   # bottom thin   ...*
    "┠", "╂", "╉", "╉",   # bottom heavy  ...*
    "┠", "╂", "╉", "╉",   # bottom double ****
    # top heavy  right heavy 
    "┗", "┺", "┻", "┻",   # bottom none   ...*
    "┡", "╄", "╇", "╇",   # bottom thin   ...*
    "┣", "╊", "╋", "╋",   # bottom heavy  ...*
    "┣", "╊", "╋", "╋",   # bottom double ****
    # top heavy  right double
    "┗", "┺", "┻", "┻",   # bottom none   ****
    "┡", "╄", "╇", "╇",   # bottom thin   ****
    "┣", "╊", "╋", "╋",   # bottom heavy  ****
    "┣", "╊", "╋", "╋",   # bottom double ****
    # top double right none  
    "╹", "╜", "┛", "╝",   # bottom none   *.*.
    "╿", "┦", "┩", "┩",   # bottom thin   ****
    "┃", "┨", "┫", "┫",   # bottom heavy  ****
    "║", "╢", "┫", "╣",   # bottom double ..*.
    # top double right thin  
    "╙", "╨", "┹", "┹",   # bottom none   ..**
    "┞", "╀", "╃", "╃",   # bottom thin   ****
    "┠", "╂", "╉", "╉",   # bottom heavy  ****
    "╟", "╫", "╉", "╉",   # bottom double ..**
    # top double right heavy 
    "┗", "┺", "┻", "┻",   # bottom none   ****
    "┡", "╄", "╇", "╇",   # bottom thin   ****
    "┣", "╊", "╋", "╋",   # bottom heavy  ****
    "┣", "╊", "╋", "╋",   # bottom double ****
    # top double right double
    "╚", "┺", "┻", "╩",   # bottom none   .**.
    "┡", "╄", "╇", "╇",   # bottom thin   ****
    "┣", "╊", "╋", "╋",   # bottom heavy  ****
    "╠", "╊", "╋", "╬",   # bottom double .**.
  ]

func boxChar*(q: Quad): string =
  ## The glyph for `q`, degraded to the nearest weight Unicode can draw when the
  ## exact combination does not exist. Always one column, never empty; a quad
  ## with no arms is a space.
  BoxChars[q.index]

func boxChar*(top = lwNone, right = lwNone, bottom = lwNone,
              left = lwNone): string =
  ## `boxChar <#boxChar,Quad>`_ on a `quad <#quad,LineWeight,LineWeight,LineWeight,LineWeight>`_
  ## built in place, which is how most call sites want it.
  boxChar(quad(top, right, bottom, left))

func lineWeightOf*(glyph: string): LineWeight =
  ## The weight of a plain line glyph — `─ ━ ═` and `│ ┃ ║` — and `lwNone` for
  ## everything else, including corners, junctions and anything that is not a
  ## box-drawing character at all.
  ##
  ## This is the *partial* inverse of `boxChar <#boxChar,Quad>`_, and partial on
  ## purpose. A full one is not possible: the degradation ladder means two quads
  ## can come back as the same glyph, so a general `glyph -> Quad` has to choose,
  ## and the six here are the entries where there is nothing to choose between.
  ## They are also what a caller actually asks: *is this border drawn in lines,
  ## and how heavy are they* — which is the question that has to be answered
  ## before a junction can be computed against it, as `Table.headerWeight` does.
  ##
  ## Derived from the table rather than typed, so it cannot drift from it.
  ##
  ## `lwNone` is the honest answer for a border made of half blocks or `+`, and
  ## callers should read it as "not expressible as an arm", not as "no line".
  for w in [lwThin, lwHeavy, lwDouble]:
    if glyph == boxChar(top = w, bottom = w) or
       glyph == boxChar(right = w, left = w): return w
  lwNone

static:
  # What a bad table breaks, checked at compile time for the reason `width.nim`
  # checks its ranges there: every failure below produces output of exactly the
  # right size, so nothing downstream can catch one.
  doAssert BoxChars.len == 256

  # No hole anywhere. The degradation ladder is meant to leave none, and an
  # empty entry would be a cell the caller draws nothing into — a gap in a frame
  # rather than a wrong glyph.
  for s in BoxChars:
    doAssert s.len > 0

  # Anchors, one per shape the table has to get right. These are also the
  # entries Textual's hand-typed version has wrong, which is what prompted
  # generating this one.
  doAssert boxChar() == " "
  doAssert boxChar(lwThin, lwThin, lwThin, lwThin) == "┼"
  doAssert boxChar(lwHeavy, lwHeavy, lwHeavy, lwHeavy) == "╋"
  doAssert boxChar(lwDouble, lwDouble, lwDouble, lwDouble) == "╬"
  doAssert boxChar(right = lwThin, bottom = lwThin) == "┌"
  doAssert boxChar(top = lwThin, left = lwThin) == "┘"
  doAssert boxChar(right = lwThin, left = lwThin) == "─"
  doAssert boxChar(top = lwThin, bottom = lwThin) == "│"
  # The mixed-weight entries, which are the only reason any of this is worth a
  # table: a thin rule meeting a double frame, and the same the other way round.
  doAssert boxChar(lwThin, lwDouble, lwThin, lwDouble) == "╪"
  doAssert boxChar(lwDouble, lwThin, lwDouble, lwThin) == "╫"
  doAssert boxChar(right = lwDouble, bottom = lwThin, left = lwDouble) == "╤"
  doAssert boxChar(top = lwDouble, right = lwThin, bottom = lwDouble) == "╟"

  # `combine` is the operation the table exists to support, so it is asserted
  # against the table rather than only against itself.
  doAssert boxChar(combine(quad(right = lwThin, left = lwThin),
                           quad(top = lwThin, bottom = lwThin))) == "┼"
  doAssert combine(quad(top = lwHeavy), quad(top = lwNone)).top == lwHeavy
  doAssert combine(quad(top = lwHeavy), quad(top = lwThin)).top == lwThin

  # The partial inverse agrees with the table in both directions, for the six
  # glyphs it claims and for a sample of the shapes it must decline.
  for w in [lwThin, lwHeavy, lwDouble]:
    doAssert lineWeightOf(boxChar(top = w, bottom = w)) == w
    doAssert lineWeightOf(boxChar(right = w, left = w)) == w
  for s in ["┼", "┌", "╬", "▌", "+", " ", "", "x"]:
    doAssert lineWeightOf(s) == lwNone
