## nimtui — build terminal UIs from a model, an update and a view.
##
## Inspired by Go's Bubble Tea: state lives in one immutable model, all changes
## go through `update`, and `view` is a pure function producing the frame. The
## runtime owns the terminal, decodes input into messages and redraws when the
## view changes.
##
## ```nim
## import nimtui
##
## type Model = object
##   count: int
##
## proc update(m: Model, msg: Msg): (Model, Cmd) =
##   result = (m, nil)
##   if msg of KeyMsg:
##     let k = KeyMsg(msg)
##     case $k
##     of "q", "ctrl+c": result[1] = quitCmd()
##     of "up": result[0].count.inc
##     of "down": result[0].count.dec
##     else: discard
##
## proc view(m: Model): string =
##   "count: " & $m.count & "\n(up/down to change, q to quit)"
##
## when isMainModule:
##   discard newProgram(Model(), update, view).run()
## ```
##
## Layers, lowest first — import a submodule directly if you only need part of it:
##
## * `nimtui/ansi` — escape sequences, visible-width helpers
## * `nimtui/color` — colour values, mixing, gradients
## * `nimtui/messages` — the `Msg` hierarchy and `Cmd` constructors
## * `nimtui/input` — pure byte-stream to `Msg` decoding
## * `nimtui/style` — SGR colours and attributes
## * `nimtui/renderer` — diff-skipping line renderer
## * `nimtui/tty` — raw mode and terminal size (the only POSIX-specific module)
## * `nimtui/query` — asking the terminal a question, and reading its answer
## * `nimtui/program` — the event loop
##
## Building a view out of blocks of text, independent of the runtime:
##
## * `nimtui/spans` — one line carrying several styles
## * `nimtui/layout` — padding, joining, wrapping, bordered panels, overlays
## * `nimtui/widgets` — bars, charts, spinners, tabs, status bars, key hints
## * `nimtui/table` — columns that line up
## * `nimtui/theme` — a palette and the styles derived from it
##
## Components, which hold state and consume keys:
##
## * `nimtui/viewport` — a scrolling window over a list of items
## * `nimtui/listview` — a list with a highlighted row
## * `nimtui/textarea` — a read-only scrolling pane over wrapped text
## * `nimtui/textinput` — a single-line editable field

import nimtui/[ansi, color, messages, input, style, renderer, tty, query, program,
               spans, layout, widgets, table, theme,
               viewport, listview, textarea, textinput]
export ansi, color, messages, input, style, renderer, tty, query, program
export spans, layout, widgets, table, theme
export viewport, listview, textarea, textinput
