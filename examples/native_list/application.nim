## Shared real application used by the desktop entry and integration tests.
## The database is borrowed; main owns it until run() has closed the Runtime.
import leaf/[core, widgets, components]
import ./store

type
  RowProps = object
    storage: ListStore
    id: int
  Draft = object
    item: ListItem
    status: string

let ItemRow = defineComponent[RowProps, State[Draft]]("NativeListItem",
  proc(ctx: MountContext, props: RowProps): State[Draft] =
    ctx.state(Draft(item: props.storage.loadItem(props.id))),
  proc(ctx: ComponentContext, props: RowProps, state: State[Draft]): UiDescription =
    let current = ctx.value(state)
    let suffix = $props.id
    host(row(@[
      column(@[
        text("记录 " & suffix & " · 稳定 id / SQLite", key = "title-" & suffix),
        input(current.item.note, key = "edit-" & suffix,
          placeholder = "输入中文或 emoji，点击保存后才写入 SQLite",
          styles = style({"width": "full"}),
          onChange = proc(event: Event) =
            discard state.update(proc(value: Draft): Draft =
              result = value
              result.item.note = event.value
              result.status = "未保存")),
        text("复合行：输入框、复选框、保存按钮与多行文字。\n滚动不写数据库。",
          key = "description-" & suffix, styles = style({"height": "32"}))],
        key = "fields-" & suffix, styles = style({"width": "full", "gap": "2"})),
      checkbox("完成", current.item.done, key = "done-" & suffix,
        onChange = proc(event: Event) =
          discard state.update(proc(value: Draft): Draft =
            result = value
            result.item.done = event.checked
            result.status = "未保存")),
      button("保存 " & suffix, key = "save-" & suffix,
        onClick = proc(event: Event) =
          var status = "已保存"
          try:
            props.storage.saveItem(current.item)
          except DatabaseError as error:
            status = "保存失败：" & error.msg
          let outcome = status
          discard state.update(proc(value: Draft): Draft =
            result = value
            result.status = outcome)),
      text(current.status, key = "status-" & suffix,
        styles = style({"width": "100"}))], key = "item-" & suffix,
      styles = style({"height": "96", "width": "full", "gap": "8"}))))

proc nativeListApp*(storage: ListStore): Application =
  var keys: seq[string]
  for id in 0 ..< ListItemCount: keys.add($id)
  let rows = componentList("items", keys,
    proc(index: int): UiDescription = component(ItemRow,
      RowProps(storage: storage, id: index)),
    rowHeight = 96, overscan = 1,
    styles = style({"height": "480", "width": "full"}))
  let root = hostShell(column(@[], key = "root",
    styles = style({"padding": "16", "gap": "8", "width": "full"})), @[
      host(text("10k 原生复合行 · SQLite 保存与重开", key = "heading")),
      host(text("未保存草稿仅在行 State 中保留；行被淘汰或关闭后会丢弃。",
        key = "help")), rows])
  componentApplication(root, "Leaf Native List", 1000, 620)
