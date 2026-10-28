## Functional laboratory, not a formal benchmark or a display-FPS monitor.
import std/[options, strutils]
import leaf
import ./scene

proc bounded(point: Vec2): Vec2 =
  vec2(max(20.0,min(940.0,point.x)),max(20.0,min(520.0,point.y)))

component GraphicsLab:
  state:
    # Private immutable SceneStorage: identity snapshot is safe; no writable alias.
    scene = stateValue(newLabScene(),snapshot=proc(value:LabScene):LabScene=value)
    running = false
    seekText = "50"
    status = "已暂停；单步是 1/120 周期，不是显示帧。"
    dot = vec2(860,80)
    selected = false
    dragging = false
    clicks = 0
  animation:
    phase = tween(0.0,1.0,duration=4000.ms,repeat=forever)
  view:
    column:
      padding: 16
      gap: 6
      text "Leaf 图形实验室：参数／时间轴／单步":
        key: "title"
      text "演示可点击／拖动圆点；压力场景不含该圆点。这里不报告 FPS。"
      row:
        gap: 8
        button "播放":
          key: "play"
          onClick:
            if phase >= 1: phase.restart()
            else: phase.play()
            running = true
            status = "播放中"
        button "暂停":
          key: "pause"
          onClick:
            phase.pause()
            running = false
            status = "已暂停"
        button "单步":
          key: "step"
          onClick:
            phase.pause()
            phase.seek(steppedCursor(phase))
            running = false
            status = "单步 1/120 周期"
        button "中点":
          key: "seek-half"
          onClick:
            phase.pause()
            phase.seek(0.5)
            running = false
            status = "定位 50%"
        button "归零":
          key: "reset"
          onClick:
            phase.reset()
            running = false
            status = "时间轴归零"
        text formatFloat(phase*100,ffDecimal,2) & "%":
          key: "cursor"
      row:
        gap: 8
        text "定位百分比（0–100，Enter确认）："
        input seekText:
          key: "seek-input"
          width: 130
          onChange(e): seekText = e.value
          onSubmit:
            try:
              let cursor = parseCursor(seekText)
              phase.pause()
              phase.seek(cursor)
              running = false
              status = "已定位"
            except LabError:
              status = "请输入 0–100 的有限百分比"
      row:
        gap: 8
        button "演示 16":
          key: "demo"
          onClick:
            scene = newLabScene()
            phase.reset()
            running = false
            dot = vec2(860,80)
            selected = false
            clicks = 0
            status = "演示已重置"
        button "100 对象":
          key: "count-100"
          onClick: scene = scene.reconfigured(count=100)
        button "1000 对象":
          key: "count-1000"
          onClick: scene = scene.reconfigured(count=1000)
        button "10000 对象":
          key: "count-10000"
          onClick: scene = scene.reconfigured(count=10000)
        text "对象："
        text scene.objectCount+(if scene.objectCount==16:1 else:0):
          key: "objects"
      row:
        gap: 8
        button "固定帧":
          key: "load-static"
          onClick: scene = scene.reconfigured(load=some(LabLoad.staticFrame))
        button "属性":
          key: "load-properties"
          onClick: scene = scene.reconfigured(load=some(LabLoad.properties))
        button "动态几何":
          key: "load-geometry"
          onClick: scene = scene.reconfigured(load=some(LabLoad.geometry))
        text $scene.load:
          key: "load"
        button "尺寸 +":
          key: "size-up"
          onClick: scene = scene.reconfigured(sizeDelta=0.1)
        button "尺寸 -":
          key: "size-down"
          onClick: scene = scene.reconfigured(sizeDelta= -0.1)
        button "透明度 -":
          key: "opacity-down"
          onClick: scene = scene.reconfigured(opacityDelta= -0.1)
        button "透明度 +":
          key: "opacity-up"
          onClick: scene = scene.reconfigured(opacityDelta=0.1)
      canvas:
        key: "drawing"
        height: 360
        viewBox: (960,540)
        background: "#101820"
        focusable: true
        accessibleLabel: "Leaf 实验室；空格播放暂停，方向键定位，Home归零，圆点可点击拖动"
        onKeyDown(e):
          case e.keyCode
          of 32:
            if running:
              phase.pause()
              running = false
            else:
              if phase >= 1: phase.restart()
              else: phase.play()
              running = true
          of 37,39:
            phase.pause()
            phase.seek(steppedCursor(phase,(if e.keyCode==37: -0.05 else:0.05)))
            running = false
          of 36:
            phase.reset()
            running = false
          else: discard
        for part in scene.sampledItems(phase):
          group:
            key: part.id
            translate: part.translation
            rotate: part.rotation
            if part.kind==DrawKind.circle:
              circle:
                center: (0,0)
                radius: part.radius
                fill: part.fill
            elif part.kind==DrawKind.rectangle:
              rect:
                position: part.size * -0.5
                size: part.size
                fill: part.fill
            else:
              path:
                geometry: part.path
                fill: part.fill
        if scene.objectCount==16:
          circle:
            key: "interactive-dot"
            center: dot
            radius: 20
            fill: (if selected: "#FFC857" else: "#D9ECFF")
            transition:
              properties: [center,fill]
              duration: (if dragging:0.ms else:180.ms)
            onClick:
              selected = not selected
              clicks += 1
            onDragStart: dragging = true
            onDrag(e): dot = bounded(dot+e.delta)
            onDragEnd: dragging = false
            onDragCancel: dragging = false
      row:
        gap: 8
        text "命令："
        text scene.objectCount*3+(if scene.objectCount==16:1 else:0):
          key: "commands"
        text "路径段："
        text (scene.objectCount div 3)*4:
          key: "segments"
        text "圆点点击："
        text clicks:
          key: "clicks"
        button "移动圆点":
          key: "move-dot"
          onClick: dot = (if dot.x>700:vec2(100,80) else:vec2(860,80))
      text status:
        key: "status"

proc labDescription*(): UiDescription = component(GraphicsLab,())
proc runGraphicsLab*(): int =
  run(GraphicsLab,title="Leaf 图形实验室",width=1040,height=710,
    canvasRenderer=CanvasRenderer.software,motionPolicy=MotionPolicy.full)
