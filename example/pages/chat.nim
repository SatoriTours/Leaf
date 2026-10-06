import std/[strutils, algorithm]
import ../ui

type
  Side = enum
    incoming, outgoing
  Message = object
    id: int
    side: Side
    sender, body, time: string
  Conversation = ref object
    title, draft: string
    messages: seq[Message]
    nextId, unread, revision: int
    muted: bool
  Chat* = ref object
    threads: array[12, Conversation]
    active, offset, epoch: int
    renderAll, newestFirst: bool
    sourceSignature: tuple[active, revision: int, newest: bool]
    sourceNode: Node
    shownSignature: tuple[active, revision, offset: int, all, newest: bool]
    shown: seq[Message]
const
  Titles = ["产品设计组", "研发讨论", "林晓", "周然",
    "发布协调", "陈宁", "用户研究", "设计评审", "测试反馈",
    "产品灵感", "许安", "团队公告"]
const
  Bodies = ["新版界面的布局已经整理好，大家可以看看。",
    "收到，我会重点检查中文输入和滚动体验。",
    "图表数据已更新，筛选条件仍然保留。",
    "这条消息用于观察大量聊天气泡的布局与换行。",
    "任务已经完成，稍后一起验收。",
    "今天的讨论记录已同步到工作区，欢迎补充意见。"]
const
  Limit = 1000
const
  Window = 50
proc floorDiv(value, divisor: int): int =
  result = value div divisor
  if value < 0 and value mod divisor != 0:
    dec result

proc positiveMod(value, divisor: int): int =
  ((value mod divisor) + divisor) mod divisor

proc message(id, chatId: int; side: Side; body = ""): Message =
  let minutes = 540 + id
  Message(id: id, side: side, sender:
    if side == outgoing:
      "我"
    else:
      ["林晓", "陈宁", "周然"][positiveMod(id + chatId, 3)]
  , body:
    if body.len == 0:
      Bodies[positiveMod(id + chatId, 6)]
    else:
      body
  , time: "07-" & align($(15 + floorDiv(minutes, 1440)), 2, '0') & " " &
      align($positiveMod(floorDiv(minutes, 60), 24), 2, '0') &
      ":" &
      align($positiveMod(minutes, 60), 2, '0'))

proc historyMessage(id, chatId: int): Message =
  message(id, chatId, if positiveMod(id, 5) == 0:
    outgoing
  else:
    incoming)

proc newChat*(messageCount = 80; renderAll = false): Chat =
  if messageCount < 1 or messageCount > Limit:
    fail("unsupported chat size")
  result = Chat(active: 1, renderAll: renderAll, newestFirst: true)
  for i, name in Titles:
    let count = if i == 0:
      messageCount
    else:
      20
    result.threads[i] = Conversation(title: name, nextId: count + 1)
    for id in 1 .. count:
      result.threads[i].messages.add(historyMessage(id, i + 1))

proc current(state: Chat): Conversation =
  state.threads[state.active - 1]

proc selectConversation(state: Chat; id: int) =
  state.active = id
  state.offset = 0
  inc state.epoch
  state.current.unread = 0

proc appendMessages(state: Chat; id, count: int; side = incoming; body = "") =
  let thread = state.threads[id - 1]
  for number in thread.nextId ..< thread.nextId + count:
    thread.messages.add(message(number, id, side, body))
  if thread.messages.len > Limit:
    thread.messages = thread.messages[thread.messages.len - Limit ..^ 1]
  thread.nextId += count
  inc thread.revision
  if id == state.active:
    thread.unread = 0
    inc state.epoch
  else:
    thread.unread += count

proc send(state: Chat) =
  let value = state.current.draft.strip
  if value.len == 0:
    return
  state.appendMessages(state.active, 1, outgoing, value)
  state.current.draft = ""
  state.offset = 0

proc receive(state: Chat; count = 1) =
  state.appendMessages(state.active, count)
  state.offset = 0

proc loadHistory(state: Chat) =
  let thread = state.current
  let count = min(200, Limit - thread.messages.len)
  if count == 0:
    return
  let first = thread.messages[0].id - count
  var earlier: seq[Message]
  for id in first ..< first + count:
    earlier.add(historyMessage(id, state.active))
  thread.messages = earlier & thread.messages
  inc thread.revision
  state.offset = min(state.offset + count, thread.messages.len - Window)

proc stress(state: Chat) =
  let thread = state.current
  thread.messages.setLen(0)
  for id in 1 .. Limit:
    thread.messages.add(historyMessage(id, state.active))
  thread.nextId = Limit + 1
  inc thread.revision
  state.offset = 0
  inc state.epoch

proc messageView(entry: Message; chatId: int): Node =
  let outgoing = entry.side == outgoing
  view:
    line:
      key: "message_" & $chatId & "_" & $entry.id
      styles: {"min_height": "90", "justify": (if outgoing: "end" else: "start")}
      stack:
        gap: 8
        styles: {"padding": "12", "min_height": "74", "width": "390", "radius": "12", "background": (if outgoing: "#1B4146" else: Background), "border_width": "1", "border_color": Border}
        text(entry.sender & " · " & entry.time & (if outgoing: " · 已送达" else: "")):
          styles: {"font_size": "11", "color": (if outgoing: Accent else: Muted)}
        text(entry.body):
          key: "message_body_" & $chatId & "_" & $entry.id
          styles: {"font_size": "13"}

proc conversationView(state: Chat; id: int): Node =
  let entry = state.threads[id - 1]
  view:
    stack:
      key: "conversation_card_" & $id
      gap: 6
      styles: {"min_height": "70"}
      button(entry.title):
        key: "conversation_" & $id
        variant: (if state.active == id: "primary" else: "ghost")
        styles: {"width": "full"}
        onClick(e): state.selectConversation(id)
      line:
        gap: 6
        label("未读")
        text($entry.unread):
          key: "unread_" & $id
          styles: {"font_size": "11", "color": (if entry.unread > 0: Accent else: Muted)}
        text((if entry.draft.len == 0: "" else: "草稿")):
          styles: {"font_size": "10", "color": "#FBBF24"}

proc cachedConversation(state: Chat; ctx: BuildContext; id: int): Node =
  let entry = state.threads[id - 1]
  proc renderConversation(): Node =
    state.conversationView(id)

  ctx.cached("chat/conversation/" & $id, $(state.active == id) & ":" &
      $entry.unread &
      ":" &
      $(entry.draft.len == 0), renderConversation)

proc render*(state: Chat; ctx: BuildContext): Node =
  let thread = state.current
  let start = max(thread.messages.len - state.offset - Window, 0)
  let shownSignature = (state.active, thread.revision, state.offset,
                        state.renderAll, state.newestFirst)
  if state.shown.len == 0 or state.shownSignature != shownSignature:
    state.shown = if state.renderAll:
      thread.messages
    else:
      thread.messages[start ..< min(start + Window, thread.messages.len)]
    if state.newestFirst:
      state.shown.reverse()
    state.shownSignature = shownSignature
  let shown = state.shown
  var conversations: seq[Node]
  for id in 1 .. Titles.len:
    conversations.add(state.cachedConversation(ctx, id))
  var rows: Node
  if state.renderAll:
    let signature = (state.active, thread.revision, state.newestFirst)
    if state.sourceNode == nil or state.sourceSignature != signature:
      let chatId = state.active
      let messages = shown
      var keys: seq[string]
      for entry in messages:
        keys.add("message_" & $chatId & "_" & $entry.id)
      proc buildMessage(i: int): Node =
        messageView(messages[i], chatId)

      state.sourceNode = view:
        virtualList:
          key: "message_list"
          keys: keys
          builder: buildMessage
          estimatedHeight: 100
          styles: {"height": "420", "min_height": "420", "width": "full", "gap": "10"}
      state.sourceSignature = signature
    rows = view:
      stack:
        key: "message_viewport_" & $state.active & "_" & $state.epoch
        styles: {"height": "420", "min_height": "420"}
        state.sourceNode
  else:
    var visible: seq[Node]
    for entry in shown:
      visible.add(messageView(entry, state.active))
    rows = view:
      stack:
        key: "message_list"
        gap: 10
        styles: {"height": "420", "min_height": "420", "overflow": "scroll"}
        children: visible
  view:
    page("团队即时聊天", "多会话、消息气泡、未读计数与历史数据，模拟高频消息更新。"):
      height: 870
      line:
        gap: 8
        button("模拟收到消息"):
          key: "chat_incoming"
          variant: "outline"
          onClick(e): state.receive()
        button("注入 100 条"):
          key: "chat_batch"
          onClick(e): state.receive(100)
        button("1000 条压力数据"):
          key: "chat_stress"
          variant: "outline"
          onClick(e): state.stress()
        button("模拟群广播"):
          key: "chat_broadcast"
          variant: "ghost"
          onClick(e):
            for id in 1 .. Titles.len:
              state.appendMessages(id, 1)
      line:
        styles: {"min_height": "660"}
        card:
          key: "conversations"
          styles: {"width": "166", "min_width": "166", "height": "660", "padding": "12", "gap": "12"}
          title("会话 / " & $Titles.len):
            size: 16
          separator()
          stack:
            key: "conversation_list"
            styles: {"flex_grow": "1", "min_height": "0", "overflow": "scroll"}
            children: conversations
        card:
          key: "chat_thread_" & $state.active
          styles: merged(grow(), style({"height": "660", "padding": "16", "gap": "12"}))
          line:
            gap: 8
            title(thread.title):
              key: "chat_title"
              size: 17
            tag("本地模拟"):
              variant: "info"
          line:
            gap: 8
            button("加载 200 条历史"):
              key: "chat_load"
              variant: "ghost"
              disabled: thread.messages.len >= Limit
              onClick(e): state.loadHistory()
            button("更早消息"):
              key: "chat_older"
              variant: "ghost"
              disabled: state.renderAll or start == 0
              onClick(e): state.offset = min(state.offset + Window, thread.messages.len - Window)
            button("最新"):
              key: "chat_latest"
              variant: "outline"
              disabled: state.offset == 0
              onClick(e):
                state.offset = 0
                inc state.epoch
          separator()
          rows
          separator()
          line:
            gap: 8
            input(thread.draft):
              key: "chat_draft"
              placeholder: "输入消息，Enter 发送"
              styles: grow()
              onChange(e): state.current.draft = e.value
              onSubmit(e): state.send()
            button("发送"):
              key: "chat_send"
              disabled: thread.draft.strip.len == 0
              onClick(e): state.send()
          label((if state.newestFirst: "最新消息置顶，方便观察注入结果。" else: "按时间正序显示，可滚动查看。"))
        card:
          key: "chat_details"
          styles: {"width": "176", "min_width": "176", "gap": "18", "padding": "16"}
          title("会话信息"):
            size: 16
          label("历史消息总数")
          title($thread.messages.len):
            key: "chat_total"
            size: 32
          label("当前数据范围")
          title($shown.len):
            key: "chat_rendered"
            size: 24
          separator()
          switch("完整数据 / 虚拟列表", state.renderAll):
            key: "chat_full"
            onChange(e):
              state.renderAll = e.checked
              state.offset = 0
          checkbox("最新在上", state.newestFirst):
            key: "chat_newest"
            onChange(e):
              state.newestFirst = e.checked
              inc state.epoch
          switch("免打扰", thread.muted):
            key: "chat_mute"
            onChange(e): state.current.muted = e.checked
          separator()
          label("分页模式构建 50 条气泡；完整数据模式仅按视口构建，长消息保持实际高度。")
          label("每个会话最多保留 1000 条消息，草稿独立保存。")
      label("消息与未读状态均为本地模拟；加载历史或切换顺序可以观察不同位置的更新。")
