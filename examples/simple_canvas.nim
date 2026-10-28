## Explicit software mode makes the renderer choice reproducible on a VM.
## Direct2D/DirectWrite remain native; no per-shape window or runtime DSL.
import leaf

component CanvasDemo:
  state:
    radius = 28.0
  view:
    column:
      padding: 16
      gap: 12
      text "Leaf 基础 Canvas"
      canvas:
        height: 360
        viewBox: (640, 360)
        background: "#101820"
        rect:
          position: (24, 24)
          size: (592, 312)
          radius: 16
          fill: "#1B2936"
        for index in 0..<3:
          circle:
            center: (120 + index * 120, 180)
            radius: radius
            fill: "#5ED5B0"
        group:
          translate: (480, 150)
          rotate: 30.deg
          clip: (0, 0, 100, 100)
          rect:
            position: (0, 0)
            size: (140, 60)
            fill: "#F4BB5F"
        path:
          stroke: "#5ED5B0"
          strokeWidth: 3
          moveTo (60, 260)
          curveTo (180, 260), (220, 80), (560, 80)
        text "Leaf 中文 ✓":
          position: (48, 48)
          size: 20
          fill: "#FFFFFF"
      row:
        gap: 8
        button "增大":
          onClick:
            radius = min(56.0, radius + 4.0)
        button "重置":
          onClick:
            radius = 28.0

when isMainModule:
  quit(run(CanvasDemo, title = "Leaf 基础绘图", width = 720, height = 520,
    canvasRenderer = CanvasRenderer.software))
