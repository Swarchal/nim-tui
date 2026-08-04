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
## * `nimtui/messages` — the `Msg` hierarchy and `Cmd` constructors
## * `nimtui/input` — pure byte-stream to `Msg` decoding
## * `nimtui/style` — SGR colours and attributes
## * `nimtui/renderer` — diff-skipping line renderer
## * `nimtui/tty` — raw mode and terminal size (the only POSIX-specific module)
## * `nimtui/program` — the event loop
##
## Building a view out of blocks of text, independent of the runtime:
##
## * `nimtui/layout` — padding, joining, bordered panels
## * `nimtui/widgets` — bars, charts, spinners, key hints

import nimtui/[ansi, messages, input, style, renderer, tty, program,
               layout, widgets]
export ansi, messages, input, style, renderer, tty, program, layout, widgets
