import std/sequtils
import ../ui

type
  Candle = object
    id, opening, closing, high, low, volume: int
  Stocks* = ref object
    symbolIndex, windowSize, frame: int
    candles: seq[Candle]
const
  Symbols = ["Leaf", "NOVA", "LUMA"]
const
  Up = "#F87171"
const
  Down = "#5EEAD4"
proc makeCandle(state: Stocks; id, opening: int): Candle =
  let closing = max(opening + (id * 37 + state.symbolIndex * 17) mod 101 - 48,
                    5000)
  Candle(id: id, opening: opening, closing: closing,
         high: max(opening, closing) + 15 + id mod 7 * 6,
         low: min(opening, closing) - 12 - id mod 5 * 8,
         volume: 200 + id * 71 mod 900)

proc reset(state: Stocks) =
  state.candles.setLen(0)
  var price = 10000 + state.symbolIndex * 3500
  for id in 1 .. 240:
    let candle = state.makeCandle(id, price)
    state.candles.add(candle)
    price = candle.closing
  state.frame = 0

proc newStocks*(windowSize = 120): Stocks =
  if windowSize notin [60, 120, 240]:
    fail("unsupported candle window")
  result = Stocks(windowSize: windowSize)
  result.reset()

proc advance(state: Stocks; count = 1) =
  for i in 0 ..< count:
    let last = state.candles[^1]
    state.candles.add(state.makeCandle(last.id + 1, last.closing))
  if state.candles.len > 240:
    state.candles = state.candles[^240 ..^ 1]
  state.frame += count

proc symbolButton(state: Stocks; index: int): Node =
  view:
    button(Symbols[index]):
      key: "stock_symbol_" & $index
      variant: (if state.symbolIndex == index: "primary" else: "outline")
      onClick(e):
        state.symbolIndex = index
        state.reset()

proc windowButton(state: Stocks; count: int): Node =
  view:
    button($count):
      key: "stock_window_" & $count
      variant: (if state.windowSize == count: "primary" else: "ghost")
      onClick(e): state.windowSize = count

proc candleView(candle: Candle; highest: int; scale: float64): Node =
  let top = float64(highest - candle.high) * scale
  let upper = float64(candle.high - max(candle.opening, candle.closing)) * scale
  let body = max(float64(abs(candle.opening - candle.closing)) * scale, 1)
  let lower = float64(min(candle.opening, candle.closing) - candle.low) * scale
  let bottom = max(200 - top - upper - body - lower, 0)
  let color = if candle.closing >= candle.opening:
    Up
  else:
    Down
  view:
    stack:
      key: "candle_" & $candle.id
      gap: 0
      styles: merged(grow(), style({"height": "200"}))
      segment:
        height: top
      segment:
        height: upper
        width: "1"
        color: color
      segment:
        height: body
        color: color
      segment:
        height: lower
        width: "1"
        color: color
      segment:
        height: bottom

proc render*(state: Stocks; ctx: BuildContext): Node =
  let visible = state.candles[^state.windowSize ..^ 1]
  let latest = state.candles[^1]
  let highest = visible.mapIt(it.high).max + 50
  let lowest = visible.mapIt(it.low).min - 50
  proc renderChart(): Node =
    var candles, volumes, axis: seq[Node]
    for candle in visible:
      candles.add(candleView(candle, highest, 200.0 / float64(highest - lowest)))
      let volumeBar = view:
        segment:
          height: float64(candle.volume) * 60 / 1100
          color: (if candle.closing >= candle.opening: Up else: Down)
          key: "volume_" & $candle.id
          align: "end"
      volumes.add(volumeBar)
    for i in 0 .. 4:
      let axisLabel = view:
        label(decimal(highest - (highest - lowest) * i div 4))
      axis.add(axisLabel)
    var averages: seq[Node]
    for period in [5, 20]:
      var sum = 0
      for candle in state.candles[^period ..^ 1]:
        sum += candle.closing
      let averageLabel = view:
        label("MA" & $period & "  " & decimal(sum div period))
      averages.add(averageLabel)
    view:
      stack:
        line:
          stack:
            styles: {"width": "58", "height": "200"}
            children: axis
          line:
            key: "candles"
            gap: 1
            styles: {"height": "200", "min_width": "0"}
            children: candles
        line:
          label("VOL")
          line:
            key: "volumes"
            gap: 1
            styles: {"height": "60"}
            children: volumes
        line:
          label("帧 " & $visible[0].id)
          label($visible.len & " 根 K 线")
          label("帧 " & $latest.id)
        separator()
        line:
          children: averages

  let chart = ctx.cached("stocks/chart", $state.symbolIndex & "/" &
      $state.frame &
      "/" &
      $state.windowSize, renderChart)
  var buttons, sizes, quotes: seq[Node]
  for i in 0 .. 2:
    buttons.add(state.symbolButton(i))
  let quoteHint = view:
    label("合成行情 · 红涨绿跌")
  buttons.add(quoteHint)
  let tickButton = view:
    button("推进 1 帧"):
      key: "stock_tick"
      onClick(e): state.advance()
  buttons.add(tickButton)
  let batchButton = view:
    button("推进 50 帧"):
      key: "stock_batch"
      onClick(e): state.advance(50)
  buttons.add(batchButton)
  for count in [60, 120, 240]:
    sizes.add(state.windowButton(count))
  for i, pair in [("最新价", decimal(latest.closing)),
                  ("区间最高", decimal(highest - 50)),
                  ("区间最低", decimal(lowest + 50)),
                  ("本帧成交量", $latest.volume)]:
    let quoteCard = view:
      card:
        key: "quote_" & $i
        styles: grow()
        label(pair[0])
        title(pair[1]):
          size: 26
    quotes.add(quoteCard)
  var book = views:
    title("模拟盘口 / 十档"):
      size: 16
    line:
      label("价格")
      label("数量")
  for level in countdown(10, 1):
    let askRow = view:
      line:
        key: "ask_" & $level
        text(decimal(latest.closing + level * 5)):
          styles: {"color": Up}
        label($(latest.volume + level * 43))
    book.add(askRow)
  let divider = view:
    separator()
  book.add(divider)
  let currentPrice = view:
    title(decimal(latest.closing)):
      size: 22
  book.add(currentPrice)
  for level in 1 .. 10:
    let bidRow = view:
      line:
        key: "bid_" & $level
        text(decimal(latest.closing - level * 5)):
          styles: {"color": Down}
        label($(latest.volume + level * 29))
    book.add(bidRow)
  view:
    page("行情实验室", "模拟 OHLC 与成交量，测试密集图元、盘口列表和连续数据替换。"):
      height: 1030
      line:
        children: buttons
      line:
        children: quotes
      line:
        card:
          key: "stock_chart"
          styles: grow()
          line:
            title(Symbols[state.symbolIndex] & " / USD"):
              key: "stock_symbol"
            sizes
          label("开 " & decimal(latest.opening) & "  高 " & decimal(latest.high) & "  低 " & decimal(latest.low) & "  收 " & decimal(latest.closing)):
            key: "stock_ohlc"
          separator()
          chart
          label("切换数量可观察细柱密集排列；推进时保留最近 240 根。")
        card:
          key: "order_book"
          styles: {"width": "210"}
          children: book
      line:
        label("已推进帧数")
        text($state.frame):
          key: "stock_frame"
        button("重置行情"):
          key: "stock_reset"
          onClick(e): state.reset()
