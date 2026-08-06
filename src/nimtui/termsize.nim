## The terminal's size, held in a model.
##
## Two integer fields and a `WindowSizeMsg` branch that copies into them appear
## in essentially every application, written out the same way every time:
##
## ```nim
## elif msg of WindowSizeMsg:
##   result[0].width = WindowSizeMsg(msg).width
##   result[0].height = WindowSizeMsg(msg).height
## ```
##
## This is that, as one field and one line:
##
## ```nim
## type Model = object
##   size: TermSize
##
## proc update(m: Model, msg: Msg): (Model, Cmd) =
##   result = (m, nil)
##   if result[0].size.handleResize(msg):
##     result[0].relayout()          # whatever the new size invalidates
##   elif msg of KeyMsg:
##     ...
## ```
##
## It is a **convention with a name**, not machinery: nothing in the runtime
## knows about it, and an application is free to keep its own two fields. What it
## buys is that the four lines above cannot be got subtly wrong — assigning
## `width` twice, or reading `WindowSizeMsg(msg)` after already storing part of
## it — and that every program spells the same thing the same way.
##
## The runtime cannot do this itself: delivering a size *into* a model means
## knowing the model's shape, and the model is any type the application likes.
## That is the whole reason the branch is written by hand in the first place.

import ./messages
export messages

type
  TermSize* = object
    ## The window in character cells, as last reported.
    ##
    ## Zero until the first `WindowSizeMsg` arrives, which in `program.run` is
    ## before the first frame — but *not* before `initCmd`'s messages, and never
    ## at all under `runHeadless` unless a test sends one. A view that divides by
    ## a dimension needs the same clamping it would have needed with two loose
    ## fields; this type deliberately does not pretend to a default, since the
    ## honest value before the terminal has said anything is "unknown" and there
    ## is nothing useful to guess.
    width*, height*: int

proc handleResize*(s: var TermSize, msg: Msg): bool =
  ## Store the size if `msg` is a `WindowSizeMsg`, and say whether it was one.
  ##
  ## The bool is the same contract as every component's `handleKey`: **true means
  ## the message was mine.** Not "the size changed" — that is a different question
  ## on the same bool, and one this cannot be trusted to answer usefully anyway,
  ## since `program.syncSize` already drops a resize that reports the size it
  ## last reported. So the two coincide on the real loop, and where they could
  ## differ — a test sending its own message — "was it mine" is the answer that
  ## keeps the idiom meaning one thing throughout the library. Compare `s` before
  ## and after if you genuinely need the other.
  ##
  ## Pixels are not here, for the reason `tty.pixelSize` is separate from
  ## `tty.windowSize`: most terminals report none, zero means unknown rather than
  ## empty, and only something drawing images has any use for them. A program
  ## that wants them wants the message, not a size — see `examples/keys.nim`.
  if msg of WindowSizeMsg:
    let w = WindowSizeMsg(msg)
    s.width = w.width
    s.height = w.height
    true
  else:
    false
