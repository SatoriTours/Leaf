import std/[unittest, options, math]
import leaf/graphics
import ../../examples/graphics_lab/scene

suite "graphics laboratory frozen scenes":
  test "actual command and segment counts match every frozen stress tier":
    for (count, commands, segments) in [(100,300,132),(1000,3000,1332),(10000,30000,13332)]:
      let scene = newLabScene(count=count)
      let frame = scene.frameAt(0)
      check scene.objectCount == count
      check frame.commandCount == commands
      var actualSegments = 0
      var actualObjects = 0
      for command in frame.commands:
        if command.kind == DrawKind.path: actualSegments += command.path.segmentCount
        if command.kind in {DrawKind.circle, DrawKind.rectangle, DrawKind.path}: inc actualObjects
      check actualObjects == count
      check actualSegments == segments

  test "static geometry is frozen and property motion never changes sealed paths":
    let fixed = newLabScene(count=100, load=LabLoad.staticFrame)
    check fixed.frameAt(0) == fixed.frameAt(0.75)
    let properties = newLabScene(count=100, load=LabLoad.properties)
    let first = properties.frameAt(0)
    let moved = properties.frameAt(0.25)
    check first.commandAt(0).transform != moved.commandAt(0).transform
    check first.commandAt(7).path == moved.commandAt(7).path
    check first.commandAt(1).radius == moved.commandAt(1).radius
    check first.commandAt(1).paint != moved.commandAt(1).paint

  test "dynamic geometry changes real circle rectangle and path commands":
    let scene = newLabScene(count=100, load=LabLoad.geometry)
    let first = scene.frameAt(0)
    let changed = scene.frameAt(0.25)
    check first.commandAt(1).radius != changed.commandAt(1).radius
    check first.commandAt(4).size != changed.commandAt(4).size
    check first.commandAt(7).path != changed.commandAt(7).path

  test "fixed seed is repeatable and changing seed changes the actual scene":
    let first = newLabScene(count=100, seed=123'u32).frameAt(0)
    check first == newLabScene(count=100, seed=123'u32).frameAt(0)
    check first != newLabScene(count=100, seed=124'u32).frameAt(0)

  test "invalid workload parameters and cursors fail before frame construction":
    for count in [0,10001]:
      expect LabError: discard newLabScene(count=count)
    for scale in [-1.0,0.0,Inf,NaN]:
      expect LabError: discard newLabScene(sizeScale=scale)
    for opacity in [-0.1,1.1,Inf,NaN]:
      expect LabError: discard newLabScene(opacity=opacity)
    let scene = newLabScene()
    for phase in [-0.1,1.1,Inf,NaN]:
      expect LabError: discard scene.frameAt(phase)

  test "percentage parsing and paused steps reject invalid values and clamp endpoints":
    check parseCursor(" 25 ") == 0.25
    check parseCursor("100") == 1.0
    for value in ["nan","inf","101","-1","nope",""]:
      expect LabError: discard parseCursor(value)
    check abs(steppedCursor(0)-1.0/120) < 1e-12
    check steppedCursor(1) == 1
    check steppedCursor(0,-0.05) == 0

  test "negative representable percentages cannot underflow into accepted zero":
    expect LabError: discard parseCursor("-1e-323")

  test "default property workloads keep complete primitives inside the view box":
    for count in [16,100]:
      let scene = newLabScene(count=count)
      for step in 0..120:
        for item in scene.sampledItems(float64(step)/120):
          var vertices: seq[Vec2]
          if item.kind==DrawKind.circle:
            vertices = @[item.translation-vec2(item.radius,item.radius),item.translation+vec2(item.radius,item.radius)]
          else:
            let matrix = groupTransform(translate=item.translation,rotate=item.rotation)
            if item.kind==DrawKind.rectangle:
              for x in [-0.5,0.5]:
                for y in [-0.5,0.5]:
                  vertices.add(matrix.transformPoint(vec2(x*item.size.x,y*item.size.y)))
            else:
              for segment in item.path.segments:
                if segment.kind in {PathSegmentKind.moveTo,PathSegmentKind.lineTo}:
                  vertices.add(matrix.transformPoint(segment.first))
          for vertex in vertices:
            # require prevents a viewport regression flooding the test log.
            require vertex.x >= 0 and vertex.x <= 960
            require vertex.y >= 0 and vertex.y <= 540

  test "preallocated producer sampling builds the exact shared scene without resizing":
    for count in [100,1000,10000]:
      for load in LabLoad:
        let scene = newLabScene(count=count,load=load)
        var buffer = newSeq[LabItem](count)
        let address = cast[pointer](addr buffer[0])
        for phase in [0.0,0.125,0.625]:
          scene.sampleIntoInternal(phase,buffer)
          check buffer.len == count
          check cast[pointer](addr buffer[0]) == address
          check scene.frameFromItemsInternal(buffer) == scene.frameAt(phase)

  test "producer buffers reject wrong capacity and bad cursors before mutation":
    let scene = newLabScene(count=100)
    var small = newSeq[LabItem](99)
    expect LabError: scene.sampleIntoInternal(0,small)
    expect LabError: discard scene.frameFromItemsInternal(small)
    var items = newSeq[LabItem](100)
    items[0].id = -123
    for phase in [-0.1,1.1,Inf,NaN]:
      expect LabError: scene.sampleIntoInternal(phase,items)
      check items[0].id == -123
