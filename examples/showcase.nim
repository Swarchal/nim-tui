## Every presentation piece in the library, on four tabs.
##
## What this example is really about: the parts of nimtui that exist purely to
## make a view look like something. Gradients and themes for colour, `Panel` for
## framing, `Table` for aligned data, `TextArea` and `ListView` for the two
## scrolling components, and `place` for a dialog drawn over the top of it all.
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

  Service = object
    name: string
    reqs: int
    p99: float
    healthy: bool

  Model = object
    tab: Tab
    themeIndex: int
    frame: int
    width, height: int
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

proc bodyHeight(m: Model): int = max(m.height - Chrome, 3)
proc innerWidth(m: Model): int = max(m.width - 4, 4)    # border + padding
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

  elif msg of WindowSizeMsg:
    result[0].width = WindowSizeMsg(msg).width
    result[0].height = WindowSizeMsg(msg).height
    result[0].layout()

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    # The dialog is modal: while it is up it takes every key, so the tabs
    # underneath cannot be driven blind.
    if m.showHelp:
      result[0].showHelp = false
      if $k in ["q", "ctrl+c"]: result[1] = quitCmd()
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

    case $k
    of "q", "ctrl+c": result[1] = quitCmd()
    of "?": result[0].showHelp = true
    of "tab", "l":
      result[0].tab = Tab((ord(m.tab) + 1) mod (ord(Tab.high) + 1))
      result[0].layout()
    of "shift+tab", "h":
      result[0].tab = Tab((ord(m.tab) + ord(Tab.high)) mod (ord(Tab.high) + 1))
      result[0].layout()
    of "t":
      result[0].themeIndex = (m.themeIndex + 1) mod Themes.len
    of "1": result[0].tab = tMetrics
    of "2": result[0].tab = tTable
    of "3": result[0].tab = tLogs
    of "4": result[0].tab = tList
    else: discard

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
    rows.add span(padVisible(label, 10), t.mutedStyle).render() &
             gauge(cur / 100.0, barWidth, HeatGradient) &
             span(&" {cur:5.1f}{unit}", t.accentStyle).render()
  rows.add ""

  rows.add span("cpu, last " & $min(m.cpu.len, w) & " samples",
                t.mutedStyle).render()
  rows.add sparkline(m.cpu, w, t.ramp)
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
  tbl.borderChars = SquareBorder
  tbl.borderStyle = t.borderStyle
  tbl.columns[0].headerStyle = t.titleStyle
  tbl.columns[1].headerStyle = t.titleStyle
  tbl.columns[2].headerStyle = t.titleStyle
  tbl.columns[3].headerStyle = t.titleStyle
  tbl.zebra = Style().bg(t.border.darken(0.28))

  for s in m.services:
    tbl.add(s.name,
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
    row("1 - 4", "jump to a tab"),
    row("j / k", "scroll or move the cursor"),
    row("pgup / pgdn", "scroll a page"),
    row("g / G", "top and bottom"),
    row("t", "cycle the theme"),
    row("?", "this dialog"),
    row("q", "quit"),
    "",
    t.mutedStyle.render("any key to dismiss"),
  ].join("\n")
  panel(DoubleBorder)
    .title(" keys ", aCenter)
    .pad(2)
    .shadow(t.mutedStyle)
    .styled(border = t.activeBorderStyle, title = t.titleStyle)
    .render(body, 40, 15)

proc view(m: Model): string =
  if m.width == 0 or m.height == 0: return "loading…"

  let
    t = m.theme
    uptime = (getMonoTime() - m.started).inMilliseconds.float / 1000.0
    title = gradientText(" nimtui showcase ", t.ramp, Style().bold())
    status = t.accentStyle.render(spinner(m.frame) & " live")
    header = statusBar(title & status, "",
                       t.mutedStyle.render(
                         &"{ThemeNames[m.themeIndex]} · {m.width}x{m.height} · " &
                         &"up {uptime.int}s "),
                       m.width)

  var labels: seq[string]
  for tab in Tab: labels.add $tab
  let tabs = tabBar(labels, ord(m.tab), m.width,
                    activeStyle = Style().bold().fg(t.selectionFg).bg(t.accent),
                    inactiveStyle = t.mutedStyle)

  let body =
    case m.tab
    of tMetrics: m.metricsPane
    of tTable: m.tablePane
    of tLogs: m.logs.render()
    of tList: m.listPane

  let pane = panel(RoundedBorder)
    .title(" " & $m.tab & " ")
    .footer(if m.tab == tLogs: " " & m.logs.positionLabel & " " else: "")
    .pad(1)
    .styled(border = t.activeBorderStyle, title = t.titleStyle,
            footer = t.mutedStyle)
    .render(body, m.width, m.bodyHeight)

  let footer = statusBar(
    " " & hints({"tab": "switch", "t": "theme", "?": "keys", "q": "quit"}),
    "", t.mutedStyle.render($m.tab & " "), m.width)

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
