import leaf

component Counter:
  state:
    count = 0
  view:
    column:
      padding: 24
      gap: 12
      width: fill
      height: "full"
      button "增加", key = "add":
        count += 1
      text count:
        key: "status"
      button "重置", key = "reset":
        count = 0

proc counterApplication*(): Application =
  app(Counter, title = "Leaf 组件计数器")

when isMainModule: quit(run(counterApplication()))
