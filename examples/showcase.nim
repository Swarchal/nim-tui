## Every presentation piece in the library, on five tabs.
##
## What this example is really about: the parts of nimtui that exist purely to
## make a view look like something. Gradients and themes for colour, `Panel` for
## framing, OSC 8 hyperlinks that cost no columns, `Table` for aligned data,
## `TextArea` and `ListView` for the two
## scrolling components, and `place` for a dialog drawn over the top of it all.
##
## The last tab is the four pieces that are purely about looking like something:
## `gradientFill` as an angled backdrop with a card placed on it, `bigDigits` for
## a figure three rows tall, `thinBar` beside the metrics tab's gradient `gauge`
## — the same half-cell resolution, said with `╸` instead of with a second
## colour, so it survives `NO_COLOR` where the gauge cannot — and `pulse`, a
## spinner whose motion is in the colour rather than in the glyph.
##
## Also shows the one piece of bookkeeping the components need: they hold a
## width and a height, and something has to tell them when the terminal changes
## size. That is `layout` below, called from the `WindowSizeMsg` branch — a
## `TextArea` whose wrapped form is stale renders lines wider than its pane,
## which desynchronises the whole frame rather than just that line.
##
##   nim c -r --path:src examples/showcase.nim

import std/[random, math, strutils, times, strformat]
import nimtui

const
  TickInterval = initDuration(milliseconds = 90)
  SampleInterval = initDuration(milliseconds = 350)
  LogInterval = initDuration(milliseconds = 900)
  History = 160

type
  TickMsg = ref object of Msg
  SampleMsg = ref object of Msg
  LogMsg = ref object of Msg

  Tab = enum
    tMetrics = "metrics"
    tTable = "table"
    tLogs = "logs"
    tList = "list"
    tDisplay = "display"

  Service = object
    name: string
    reqs: int
    p99: float
    healthy: bool

  Model = object
    tab: Tab
    themeIndex: int
    frame: int
    size: TermSize
    cpu, mem, net: seq[float]
    services: seq[Service]
    logs: TextArea
    list: ListView
    items: seq[string]
    showHelp: bool
    started: MonoTime

const Themes = [DefaultTheme, NeonTheme, SolarTheme, MonoTheme]
const ThemeNames = ["default", "neon", "solar", "mono"]

proc theme(m: Model): Theme = Themes[m.themeIndex]

# --- geometry -----------------------------------------------------------------
#
# One place that decides how big the body is, used by both `update` (to size the
# components) and `view` (to draw them). Two copies of this arithmetic drifting
# apart is exactly how a component ends up rendering at the wrong width.

const Chrome = 3          # header, tab strip, footer

proc bodyHeight(m: Model): int = max(m.size.height - Chrome, 3)
proc innerWidth(m: Model): int = max(m.size.width - 4, 4)    # border + padding
proc innerHeight(m: Model): int = max(m.bodyHeight - 4, 1)

proc layout(m: var Model) =
  ## Push the current geometry into the components that store their own.
  m.logs.resize(m.innerWidth, m.innerHeight)
  m.list.vp.height = m.innerHeight
  m.list.sync m.items.len

# --- fake data ----------------------------------------------------------------

var rng = initRand(0xC0FFEE)

proc walk(s: var seq[float], centre: float) =
  let last = if s.len == 0: centre else: s[^1]
  s.add clamp(last + (centre - last) * 0.08 + rng.gauss(0.0, 7.0), 0.0, 100.0)
  if s.len > History: s.delete 0

const LogLines = [
  ("info", "GET /api/items 200 in 42ms"),
  ("info", "cache hit ratio 0.94 over 2m window"),
  ("warn", "slow query 812ms: SELECT * FROM events WHERE ..."),
  ("info", "worker heartbeat ok, 4 threads idle"),
  ("error", "upstream timeout after 5s, retrying with backoff"),
  ("info", "flushed 240 events to the write-ahead log"),
  ("warn", "queue depth 1204, above the soft limit of 1000"),
]

# --- update -------------------------------------------------------------------

proc tickCmd(): Cmd = after(TickInterval, TickMsg())
proc sampleCmd(): Cmd = after(SampleInterval, SampleMsg())
proc logCmd(): Cmd = after(LogInterval, LogMsg())

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if msg of TickMsg:
    result[0].frame.inc
    result[1] = tickCmd()

  elif msg of SampleMsg:
    result[0].cpu.walk 55.0
    result[0].mem.walk 70.0
    result[0].net.walk 35.0
    for i in 0 .. result[0].services.high:
      result[0].services[i].reqs += rng.rand(200)
      result[0].services[i].p99 = clamp(
        result[0].services[i].p99 + rng.gauss(0.0, 12.0), 5.0, 400.0)
      result[0].services[i].healthy = result[0].services[i].p99 < 250.0
    result[1] = sampleCmd()

  elif msg of LogMsg:
    let (level, text) = LogLines[rng.rand(LogLines.high)]
    let stamp = (getMonoTime() - m.started).inMilliseconds.float / 1000.0
    let st = case level
             of "warn": m.theme.warnStyle
             of "error": m.theme.errorStyle
             else: m.theme.mutedStyle
    result[0].logs.add m.theme.mutedStyle.render(&"{stamp:7.1f}s ") &
                       st.render(level.toUpperAscii.alignLeft(5)) & " " & text
    result[1] = logCmd()

  elif result[0].size.handleResize(msg):
    result[0].layout()

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    # The dialog is modal: while it is up it takes every key, so the tabs
    # underneath cannot be driven blind.
    if m.showHelp:
      result[0].showHelp = false
      if k.matches("q", "ctrl+c"): result[1] = quitCmd()
      return

    # Offer the key to the focused component first, and only treat it as a
    # command if the component did not want it — the same delegation every
    # multi-component view needs.
    case m.tab
    of tLogs:
      if result[0].logs.handleKey(k): return
    of tList:
      if result[0].list.handleKey(k, m.items.len): return
    else: discard

    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("?"): result[0].showHelp = true
    elif k.matches("tab", "l"):
      result[0].tab = Tab((ord(m.tab) + 1) mod (ord(Tab.high) + 1))
      result[0].layout()
    elif k.matches("shift+tab", "h"):
      result[0].tab = Tab((ord(m.tab) + ord(Tab.high)) mod (ord(Tab.high) + 1))
      result[0].layout()
    elif k.matches("t"):
      result[0].themeIndex = (m.themeIndex + 1) mod Themes.len
    elif k.matches("1"): result[0].tab = tMetrics
    elif k.matches("2"): result[0].tab = tTable
    elif k.matches("3"): result[0].tab = tLogs
    elif k.matches("4"): result[0].tab = tList
    elif k.matches("5"): result[0].tab = tDisplay

# --- view ---------------------------------------------------------------------

proc metricsPane(m: Model): string =
  let
    t = m.theme
    w = m.innerWidth
  var rows: seq[string]

  for (label, series, unit) in [("cpu", m.cpu, "%"), ("memory", m.mem, "%"),
                                ("network", m.net, "MB/s")]:
    let
      cur = if series.len == 0: 0.0 else: series[^1]
      barWidth = max(w - 12 - 10, 4)
    # A track that is a *painted* colour rather than `░` on the terminal's own
    # background, which is what makes the bar read as one strip. Every half-block
    # cell of the bar is painted edge to edge, and `gauge` puts the track's
    # background behind the fractional cell at the end of the bar too, so bar,
    # end and track meet with nothing of the terminal's background between them.
    #
    # Both parts of that are needed and each was a visible gap on its own:
    #
    # * With no track colour, the fractional cell's remainder is terminal
    #   background — up to seven eighths of a cell of it — and the bar stops short
    #   of its own track.
    # * With a coloured background but `░` kept as the glyph, the track's
    #   *apparent* colour is that background plus the dots, which is lighter than
    #   the background alone. The fractional cell can only be a glyph over the
    #   background, so it comes out darker than the track beside it: a dark notch
    #   in exactly the place the first gap was. A solid track has no such step,
    #   because the two are then the same colour.
    #
    # Which leaves `NO_COLOR`, where a background paints nothing and a solid track
    # would be invisible — so the glyph is chosen by whether there is a colour to
    # paint with, and `░` is what a track looks like when there is not.
    #
    # The colour is `darken(0.12)` and not the larger figure it started as because
    # a track has to be *lighter* than the background it sits on: `darken`
    # subtracts lightness in HSL and every built-in border sits near L=0.33, so
    # anything past about 0.3 clips to pure black — and a black track on a dark
    # background is a hole in the pane rather than the part of the bar not yet
    # reached, which is worse than the gap it was meant to close.
    let (trackGlyph, trackStyle) =
      if colorProfile() == cpNoColor: ("░", Style().faint())
      else: (" ", Style().bg(t.border.darken(0.12)))
    rows.add span(padVisible(label, 10), t.mutedStyle).render() &
             gauge(cur / 100.0, barWidth, HeatGradient,
                   empty = trackGlyph, emptyStyle = trackStyle) &
             span(&" {cur:5.1f}{unit}", t.accentStyle).render()
  rows.add ""

  # The same series twice, at the same width, because the pair is the point: a
  # `sparkline` cell is one sample at eight heights, and a filled `lineSpark` is
  # two samples at four — same quantity reading, twice the history, and a top
  # edge that resolves the shape *between* two samples instead of averaging them
  # away. Both scale to their own window, so the two lines are directly
  # comparable; what differs is only how the cell is divided.
  # Each row says how much of its window has arrived, out of what it holds, which
  # is where the second number differs: both are `w` cells and the area's are
  # divided in two. Early on that shows as a half-filled row — both pad on the
  # left — and once the history fills, as twice as much of it on screen.
  let held = min(m.cpu.len, w)
  rows.add span(&"cpu · bars, last {held} of {w}", t.mutedStyle).render()
  rows.add sparkline(m.cpu, w, t.ramp)
  let
    window = w * dotsX(pgBraille)
    heldArea = min(m.cpu.len, window)
  rows.add span(&"cpu · area, last {heldArea} of {window}", t.mutedStyle).render()
  rows.add lineSpark(m.cpu, w, t.ramp, fill = true)
  rows.add ""

  let chartHeight = max(m.innerHeight - rows.len - 1, 2)
  rows.add span("network", t.mutedStyle).render()
  for line in barChart(m.net, w, chartHeight, t.ramp, lo = 0.0, hi = 100.0):
    rows.add line
  rows.join("\n")

proc tablePane(m: Model): string =
  let t = m.theme
  var tbl = table([column("service", minWidth = 8),
                   column("requests", align = aRight, headerAlign = aRight),
                   column("p99 ms", align = aRight, headerAlign = aRight),
                   column("status", align = aCenter, headerAlign = aCenter)])
  # A frame heavier than the rules it divides, which is `ruledBorder`'s reason
  # for existing: the five junctions where a thin rule meets a double frame are
  # `╤ ╧ ╟ ╢ ┼`, and no built-in `Border` carries them. Written out by hand it is
  # eleven glyphs and the wrong one is invisible until someone looks closely.
  tbl.borderChars = ruledBorder(lwDouble, lwThin)
  # And a third weight, on the one rule that separates two *kinds* of row. The
  # junctions are computed the same way and land on glyphs the border does not
  # carry either: `╠` and `╣` where the double rule meets the double frame, `╪`
  # where it crosses a thin column rule. Setting `innerHorizontal` to `═` instead
  # would draw the run and leave those three thin, which is the mismatch
  # `headerWeight` exists to avoid.
  tbl.headerWeight = lwDouble
  tbl.borderStyle = t.borderStyle
  tbl.columns[0].headerStyle = t.titleStyle
  tbl.columns[1].headerStyle = t.titleStyle
  tbl.columns[2].headerStyle = t.titleStyle
  tbl.columns[3].headerStyle = t.titleStyle
  # `0.28` here was `rgb(10,12,13)` — all but black, on every one of the four
  # themes, for the reason the metrics track above spells out: `darken` takes
  # lightness off in HSL and these borders start near L=0.33. A zebra is a fill
  # and survived looking like that in a way the track could not, which is why it
  # went unnoticed. `0.14` is a tint of the border in each theme.
  tbl.zebra = Style().bg(t.border.darken(0.14))

  for s in m.services:
    # An OSC 8 hyperlink in a table cell. The column still sizes to the visible
    # text — `displayWidth` measures the link as just its name, because
    # `escapeLen` already knew OSC carries a payload — so a terminal that
    # implements it makes the name clickable and one that does not shows exactly
    # the same table.
    tbl.add(link(s.name, "https://example.com/service/" & s.name),
            insertSep($s.reqs, ','),
            &"{s.p99:.1f}",
            if s.healthy: t.successStyle.render("● ok")
            else: t.errorStyle.render("● slow"))
  tbl.render(m.innerWidth)

proc listPane(m: Model): string =
  let t = m.theme
  m.list.render(m.items, m.innerWidth,
                selectedStyle = t.selectionStyle,
                itemStyle = Style(),
                scrollbarStyle = t.mutedStyle)

proc displayPane(m: Model): string =
  ## The four pieces that are about looking like something rather than about
  ## saying something: an angled gradient as a backdrop, a figure big enough to
  ## read across a room, a bar whose half-cell is in the glyph, and a spinner
  ## whose motion is entirely in the colour.
  let
    t = m.theme
    w = m.innerWidth
    h = m.innerHeight
    secs = (getMonoTime() - m.started).inMilliseconds div 1000
    cpu = if m.cpu.len == 0: 0.0 else: m.cpu[^1]
    cardWidth = min(w - 4, 52)
    # The card's interior, less the six columns of label and the eight the
    # trailing figure needs. Measured rather than guessed at, because a bar one
    # column too wide truncates the figure off the end of its own row.
    barWidth = max(cardWidth - 6 - 6 - 8, 4)

  # `bigDigits` is three rows whatever it is given, so a clock is the one thing
  # that can be laid out around it without measuring first.
  var card = @[bigDigits(&"{secs div 60:02}:{secs mod 60:02}", bold = true)]
  card.add ""
  # A thin bar beside the gradient `gauge` on the metrics tab: the same value,
  # with the half cell said by `╸` rather than by a second colour. Under
  # `NO_COLOR` this one keeps its resolution and that one cannot.
  card.add t.mutedStyle.render(padVisible("cpu", 6)) &
           thinBar(cpu / 100.0, barWidth, t.ramp) &
           t.accentStyle.render(&" {cpu:5.1f}%")
  card.add t.mutedStyle.render(padVisible("plain", 6)) &
           thinBar(cpu / 100.0, barWidth)
  card.add ""
  # `m.frame` is a 90 ms tick, so a cycle every eighteen frames is a shade under
  # two seconds — and `pulse` takes the position rather than the frame, which is
  # what lets that be chosen here rather than baked into the widget.
  card.add pulse(t.ramp, m.frame.float / 18.0) & " " &
           t.mutedStyle.render("working")

  let body = panel(EvenBlockBorder)
    .title(" display ", aCenter)
    .pad(2)
    .styled(border = t.accentStyle, title = t.titleStyle)
    .render(card.join("\n"), cardWidth, 14)

  # The backdrop is an ordinary block, which is the whole point of it being a
  # string: `place` cannot tell it from a pane and keeps its dimensions, so the
  # card sits on the gradient without either of them resizing the other.
  place(gradientFill(t.ramp, w, h, angle = 35.0), body)

proc helpDialog(m: Model): string =
  let t = m.theme
  # `keyHint` runs the key straight into the description, which is right for a
  # footer but not for a column of them — pad the key so the descriptions line
  # up, measuring with `padVisible` since the key is already styled.
  proc row(k, d: string): string =
    span(padVisible(k, 13), t.accentStyle).render() & t.mutedStyle.render(d)

  let body = @[
    "",
    row("tab / h l", "switch tabs"),
    row("1 - 5", "jump to a tab"),
    row("j / k", "scroll or move the cursor"),
    row("pgup / pgdn", "scroll a page"),
    row("g / G", "top and bottom"),
    row("t", "cycle the theme"),
    row("?", "this dialog"),
    row("q", "quit"),
    "",
    t.mutedStyle.render("any key to dismiss"),
  ].join("\n")
  # A half-block border, which is the one place in the examples that shows what
  # they are for: the frame's ink faces outward, so with the shadow under it the
  # dialog reads as a slab lifted off the frame behind rather than as a second
  # wire box drawn over the first.
  panel(OuterHalfBlockBorder)
    .title(" keys ", aCenter)
    .pad(2)
    .shadow(t.mutedStyle)
    .styled(border = t.activeBorderStyle, title = t.titleStyle)
    .render(body, 40, 15)

proc view(m: Model): string =
  if m.size.width == 0 or m.size.height == 0: return "loading…"

  let
    t = m.theme
    uptime = (getMonoTime() - m.started).inMilliseconds.float / 1000.0
    title = gradientText(" nimtui showcase ", t.ramp, Style().bold())
    status = t.accentStyle.render(spinner(m.frame) & " live")
    header = statusBar(title & status, "",
                       t.mutedStyle.render(
                         &"{ThemeNames[m.themeIndex]} · {m.size.width}x{m.size.height} · " &
                         &"up {uptime.int}s "),
                       m.size.width)

  var labels: seq[string]
  for tab in Tab: labels.add $tab
  let tabs = tabBar(labels, ord(m.tab), m.size.width,
                    activeStyle = Style().bold().fg(t.selectionFg).bg(t.accent),
                    inactiveStyle = t.mutedStyle)

  let body =
    case m.tab
    of tMetrics: m.metricsPane
    of tTable: m.tablePane
    of tLogs: m.logs.render()
    of tList: m.listPane
    of tDisplay: m.displayPane

  let pane = panel(RoundedBorder)
    .title(" " & $m.tab & " ")
    .footer(if m.tab == tLogs: " " & m.logs.positionLabel & " " else: "")
    .pad(1)
    .styled(border = t.activeBorderStyle, title = t.titleStyle,
            footer = t.mutedStyle)
    .render(body, m.size.width, m.bodyHeight)

  let footer = statusBar(
    " " & hints({"tab": "switch", "t": "theme", "?": "keys", "q": "quit"}),
    "", t.mutedStyle.render($m.tab & " "), m.size.width)

  let frame = joinVertical(header, tabs, pane, footer)
  # The dialog goes on last, over the finished frame: `place` keeps the frame's
  # dimensions, so a modal cannot push the layout around.
  if m.showHelp: place(frame, m.helpDialog) else: frame

when isMainModule:
  var model = Model(started: getMonoTime(), tab: tMetrics)
  model.services = @[
    Service(name: "api-gateway", reqs: 128_400, p99: 82.4, healthy: true),
    Service(name: "auth", reqs: 41_020, p99: 31.9, healthy: true),
    Service(name: "search", reqs: 9_530, p99: 268.1, healthy: false),
    Service(name: "worker", reqs: 3_180, p99: 140.7, healthy: true),
    Service(name: "日本-edge", reqs: 22_615, p99: 55.2, healthy: true),
  ]
  for i in 1 .. 60:
    model.items.add &"item {i:02} — " &
      ["deploy", "rollback", "scale up", "drain", "restart"][i mod 5]
  model.logs = initTextArea(follow = true)
  model.list = initListView()
  discard newProgram(model, update, view,
                     options = {poAltScreen, poHideCursor},
                     initCmd = batch(tickCmd(), sampleCmd(), logCmd())).run()
