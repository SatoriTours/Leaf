## Real Windows interaction entry; no animation or performance claims.
import leaf

component CanvasInteraction:
  state:
    position = vec2(120, 120)
    clicks = 0
    cancellations = 0
    dragging = false
    selected = false
    version = 0
  view:
    column:
      padding: 16
      gap: 8
      text "点击或拖动圆点；画布支持方向键和滚轮。"
      canvas:
        key: "drawing"
        height: 240
        viewBox: (480, 240)
        background: "#101820"
        focusable: true
        accessibleLabel: "Leaf 交互画布"
        onKeyDown(e):
          case e.keyCode
          of 37: position -= vec2(10, 0)
          of 38: position -= vec2(0, 10)
          of 39: position += vec2(10, 0)
          of 40: position += vec2(0, 10)
          else: discard
        onWheel(e):
          position += vec2(e.wheelDelta.y * 10, 0)
        group:
          clip: (0, 0, 480, 240)
          circle:
            key: "dot-" & $version
            center: position
            radius: 24
            fill: (if selected: "#FFC857" else: "#5ED5B0")
            onClick:
              clicks += 1
              selected = not selected
            onDragStart:
              dragging = true
            onDrag(e):
              position += e.delta
            onDragEnd:
              dragging = false
            onDragCancel:
              dragging = false
              cancellations += 1
      text "clicks: " & $clicks
      text "x: " & $position.x
      text "dragging: " & $dragging
      text "cancellations: " & $cancellations
      row:
        gap: 8
        button "重置":
          key: "reset"
          onClick:
            position = vec2(120, 120)
            clicks = 0
            cancellations = 0
            dragging = false
            selected = false
        button "替换图元":
          key: "replace"
          onClick:
            version += 1
            dragging = false

when isMainModule:
  quit(run(CanvasInteraction, title = "Leaf 画布交互", width = 640, height = 520,
    canvasRenderer = CanvasRenderer.software))
