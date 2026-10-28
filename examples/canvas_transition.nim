## Accepted targets drive presentation-only transitions; no view runs per frame.
## Explicit software rendering and full motion keep this demo deterministic.
import leaf

var evaluations = 0
proc counted(value: float64): float64 =
  inc evaluations
  value

component TransitionScene:
  state:
    alternate = false
    replacement = 0
  view:
    column:
      padding: 20
      gap: 10
      text "Canvas 属性过渡：接受目标、从当前画面重定向":
        key: "title"
      canvas:
        key: "drawing"
        height: 250
        viewBox: (640, 250)
        background: "#101820"
        accessibleLabel: "位置、半径、颜色与旋转过渡演示"
        line:
          start: (80, 125)
          finish: (540, 125)
          stroke: "#52677B"
          strokeWidth: 3
        circle:
          key: "dot-" & $replacement
          center: (if alternate: (540, 125) else: (80, 125))
          radius: counted(if alternate: 34.0 else: 18.0)
          fill: (if alternate: "#FFB86C" else: "#5ED5B0")
          transition:
            properties: [center, radius, fill]
            duration: 900.ms
            easing: easeInOut
        group:
          key: "rotor"
          translate: (310, 125)
          rotate: (if alternate: 360 else: 0).deg
          transition:
            properties: [rotate]
            duration: 900.ms
            easing: linear
          rect:
            position: (-28, -8)
            size: (56, 16)
            radius: 4
            fill: "#A9B7FF"
        text "纯属性过渡不逐帧执行用户 view":
          position: (24, 24)
          size: 18
          fill: "#FFFFFF"
      text (if alternate: "目标 B（右侧、较大、橙色）" else: "目标 A（左侧、较小、绿色）"):
        key: "target"
      text "用户 view 求值次数：" & $evaluations:
        key: "evaluations"
      row:
        gap: 8
        button "目标 A":
          key: "target-a"
          onClick: alternate = false
        button "目标 B":
          key: "target-b"
          onClick: alternate = true
        button "中途重定向":
          key: "retarget"
          onClick: alternate = not alternate
        button "替换图元":
          key: "replace"
          onClick: replacement += 1

when isMainModule:
  quit run(TransitionScene, title="Leaf Canvas 属性过渡", width=760, height=460,
    canvasRenderer=CanvasRenderer.software, motionPolicy=MotionPolicy.full)
