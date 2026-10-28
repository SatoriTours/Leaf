## A real native/software Canvas timeline; no frame-rate claim.
import leaf

component AnimatedDot:
  state:
    status = "初始"
    finishes = 0
  animation:
    x = tween(60.0, 580.0, duration=1200.ms, easing=easeInOut,
      onFinish=proc() =
        finishes += 1
        status = "已结束")
  view:
    column:
      padding: 20
      gap: 10
      text "Canvas 时间轴：播放、暂停、中点定位与重播":
        key: "title"
      canvas:
        key: "drawing"
        height: 240
        viewBox: (640, 240)
        background: "#101820"
        focusable: true
        accessibleLabel: "可控制动画的画布"
        line:
          start: (60, 120)
          finish: (580, 120)
          stroke: "#52677B"
          strokeWidth: 3
        circle:
          center: (x, 120)
          radius: 20
          fill: "#5ED5B0"
        text "Leaf 动画":
          position: (24, 24)
          size: 18
          fill: "#FFFFFF"
      text status:
        key: "status"
      text x:
        key: "position"
      text finishes:
        key: "finishes"
      row:
        gap: 8
        button "播放":
          onClick:
            x.play()
            status = (if x == 580.0: "已结束（请重播）" else: "播放中")
        button "暂停":
          onClick:
            x.pause()
            status = "已暂停"
        button "中点":
          onClick:
            x.pause()
            x.seek(0.5)
            status = "中点（暂停）"
        button "重播":
          onClick:
            x.restart()
            status = "播放中"
        button "重置":
          onClick:
            x.reset()
            status = "初始"

when isMainModule:
  quit run(AnimatedDot, title="Leaf Canvas 动画", width=740, height=520,
    canvasRenderer=CanvasRenderer.software, motionPolicy=MotionPolicy.full)
