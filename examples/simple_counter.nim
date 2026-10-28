import leaf

component Counter:
  state:
    count = 0
  view:
    column:
      padding: 24
      gap: 12
      text count
      row:
        gap: 8
        button "增加":
          onClick:
            count += 1
        button "重置":
          onClick:
            count = 0

when isMainModule:
  quit(run(Counter, title = "Leaf 计数器", width = 400, height = 240))
