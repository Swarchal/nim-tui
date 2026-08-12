## Snake.
##
## What this example is really about: a game loop whose tick rate changes as the
## game progresses, and input that must not be trusted. Two guards matter:
##
## * a tick is stamped with the generation that scheduled it, so ticks left over
##   from a previous speed or a previous game are discarded rather than causing
##   a double step
## * direction changes are buffered and applied at the *step*, not on the
##   keypress, so mashing left-then-up within one tick cannot fold the snake
##   back into itself
##
## Also shows: a grid rendered from a set of cells, and a game-over overlay
## drawn over the same board.
##
##   nim c -r --path:src examples/snake.nim

import std/[sets, random, sequtils, strutils, math, strformat]
import nimtui

const
  StartInterval = 130
  MinInterval = 55
  StartLength = 4

type
  Dir = enum dUp, dDown, dLeft, dRight

  Cell = tuple[x, y: int]

  Phase = enum pPlaying, pPaused, pOver

  StepMsg = ref object of Msg
    generation: int

  Model = object
    snake: seq[Cell]            ## head first
    occupied: HashSet[Cell]     ## same cells, for O(1) collision checks
    food: Cell
    dir: Dir
    queued: seq[Dir]            ## direction changes awaiting the next step
    phase: Phase
    score: int
    best: int
    generation: int
    board: tuple[w, h: int]
    size: TermSize

var rng = initRand(0xbeef)

# --- rules --------------------------------------------------------------------

proc opposite(a, b: Dir): bool =
  (a == dUp and b == dDown) or (a == dDown and b == dUp) or
  (a == dLeft and b == dRight) or (a == dRight and b == dLeft)

proc step(c: Cell, d: Dir): Cell =
  case d
  of dUp: (c.x, c.y - 1)
  of dDown: (c.x, c.y + 1)
  of dLeft: (c.x - 1, c.y)
  of dRight: (c.x + 1, c.y)

proc interval(m: Model): int =
  ## Speeds up with score, floored so it stays playable.
  max(StartInterval - m.score * 4, MinInterval)

proc scheduleStep(m: Model): Cmd =
  after(initDuration(milliseconds = m.interval), StepMsg(generation: m.generation))

proc placeFood(m: var Model) =
  ## Rejection sampling is fine here: the board is never near full in practice,
  ## but bail out after a bounded number of tries rather than spinning.
  for _ in 1 .. 500:
    let c = (rng.rand(m.board.w - 1), rng.rand(m.board.h - 1))
    if c notin m.occupied:
      m.food = c
      return
  m.phase = pOver

proc reset(m: var Model) =
  let mid: Cell = (m.board.w div 2, m.board.h div 2)
  m.snake = @[]
  m.occupied.clear()
  for i in 0 ..< StartLength:
    let c = (mid.x - i, mid.y)
    m.snake.add c
    m.occupied.incl c
  m.dir = dRight
  m.queued.setLen 0
  m.score = 0
  m.phase = pPlaying
  m.generation.inc
  m.placeFood()

proc advance(m: var Model) =
  # Apply at most one buffered turn per step, dropping reversals.
  while m.queued.len > 0:
    let d = m.queued[0]
    m.queued.delete 0
    if not opposite(d, m.dir) and d != m.dir:
      m.dir = d
      break

  let head = m.snake[0].step(m.dir)
  let tail = m.snake[^1]
  let eating = head == m.food

  # The tail cell is free by the time the head arrives, unless we grow.
  if not eating: m.occupied.excl tail

  if head.x < 0 or head.y < 0 or head.x >= m.board.w or head.y >= m.board.h or
     head in m.occupied:
    m.phase = pOver
    m.best = max(m.best, m.score)
    m.generation.inc                        # invalidate ticks already in flight
    return

  m.snake.insert(head, 0)
  m.occupied.incl head
  if eating:
    m.score.inc
    m.placeFood()
  else:
    m.snake.setLen m.snake.len - 1

# --- update -------------------------------------------------------------------

proc boardSize(width, height: int): tuple[w, h: int] =
  ## Cells are two columns wide so they look square.
  (max((min(width, 100) - 4) div 2, 10), max(min(height, 40) - 6, 8))

proc update(m: Model, msg: Msg): (Model, Cmd) =
  result = (m, nil)

  if result[0].size.handleResize(msg):
    let board = boardSize(result[0].size.width, result[0].size.height)
    if board != m.board:
      result[0].board = board
      result[0].reset()
      result[1] = result[0].scheduleStep()

  elif msg of StepMsg:
    # Ignore ticks from an earlier generation: a stale one would step twice.
    if StepMsg(msg).generation != m.generation: return
    if m.phase == pPlaying:
      result[0].advance()
      if result[0].phase == pPlaying:
        result[1] = result[0].scheduleStep()
    elif m.phase == pPaused:
      result[1] = result[0].scheduleStep()

  elif msg of KeyMsg:
    let k = KeyMsg(msg)
    if k.matches("q", "ctrl+c"): result[1] = quitCmd()
    elif k.matches("up", "k", "w"): result[0].queued.add dUp
    elif k.matches("down", "j", "s"): result[0].queued.add dDown
    elif k.matches("left", "h", "a"): result[0].queued.add dLeft
    elif k.matches("right", "l", "d"): result[0].queued.add dRight
    elif k.matches("space", "p"):
      if m.phase == pPlaying: result[0].phase = pPaused
      elif m.phase == pPaused: result[0].phase = pPlaying
    elif k.matches("r", "enter"):
      if m.phase == pOver or m.phase == pPaused:
        result[0].reset()
        result[1] = result[0].scheduleStep()

# --- view ---------------------------------------------------------------------

const
  HeadColour = rgb(160, 255, 160)
  BodyColour = rgb(80, 190, 110)
  FoodColour = rgb(255, 120, 120)
  Accent = rgb(120, 220, 200)

proc boardRows(m: Model): seq[string] =
  let head = Style().fg(HeadColour).bold().render("██")
  let body = Style().fg(BodyColour).render("██")
  let food = Style().fg(FoodColour).render("◆ ")
  let empty = Style().faint().render("· ")
  for y in 0 ..< m.board.h:
    var line = ""
    for x in 0 ..< m.board.w:
      let c = (x, y)
      if c == m.snake[0]: line.add head
      elif c in m.occupied: line.add body
      elif c == m.food: line.add food
      else: line.add empty
    result.add line

proc overlay(rows: var seq[string], text: seq[string], width: int) =
  ## Draw a centred panel over the board without disturbing its dimensions.
  let boxWidth = min(text.mapIt(displayWidth(it)).max + 6, width)
  let panel = renderBox(text.mapIt(centerVisible(it, boxWidth - 2)).join("\n"),
                        boxWidth, text.len + 2,
                        borderStyle = Style().fg(Accent)).split("\n")
  let top = max((rows.len - panel.len) div 2, 0)
  let left = max((width - boxWidth) div 2, 0)
  for i, line in panel:
    if top + i < rows.len:
      # Rebuild the row: board cells are styled, so splice by visible columns.
      let row = rows[top + i]
      rows[top + i] = truncateVisible(row, left) & line &
        Style().faint().render(' '.repeat(
          max(width - left - displayWidth(line), 0)))

proc view(m: Model): string =
  if m.size.width == 0 or m.snake.len == 0: return "loading…"
  let boardWidth = m.board.w * 2
  var rows = m.boardRows()

  case m.phase
  of pOver:
    rows.overlay(@["game over", "", &"score {m.score}",
                   "r to play again · q to quit"], boardWidth)
  of pPaused:
    rows.overlay(@["paused", "space to resume"], boardWidth)
  of pPlaying: discard

  let header = Style().bold().render("  snake  ") &
    Style().fg(Accent).render(&"score {m.score}") &
    Style().faint().render(&"   best {m.best}   " &
      &"{1000 div m.interval} steps/s   {m.board.w}x{m.board.h}")

  joinVertical(header,
               renderBox(rows.join("\n"), boardWidth + 2, m.board.h + 2,
                         borderStyle = Style().faint()),
               " " & hints({"arrows/wasd": "turn", "space": "pause",
                            "r": "restart", "q": "quit"}))

when isMainModule:
  discard newProgram(Model(), update, view,
                     options = {poAltScreen, poHideCursor}).run()
