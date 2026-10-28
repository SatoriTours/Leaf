## Immutable, deterministic workload shared by the laboratory and future
## native measurement producer. No clocks, UI callbacks, or measurement IO.
import std/[math, options, strutils]
import leaf/graphics

type
  LabError* = object of ValueError
  LabLoad* {.pure.} = enum staticFrame, properties, geometry
  LabItem* = object
    id*: int
    kind*: DrawKind
    translation*, size*: Vec2
    rotation*: Degrees
    radius*: float64
    fill*: Color
    path*: PathData
  LabScene* = object
    data: SceneStorage
  SceneStorage = ref object
    items: seq[LabItem]
    fixed: CanvasFrame
    load: LabLoad
    seed: uint32
    sizeScale, opacity: float64

const
  LabSceneVersion* = "leaf-canvas-lab-v1"
  LabSeed* = 0x1EAFC0DE'u32
  LabViewWidth* = 960
  LabViewHeight* = 540

proc finite(value: float64): bool = classify(value) notin {fcNan, fcInf, fcNegInf}
proc requireCursor(value: float64) =
  if not finite(value) or value < 0 or value > 1:
    raise newException(LabError, "cursor must be finite and in 0..1")

proc objectCount*(scene: LabScene): int = scene.data.items.len
proc load*(scene: LabScene): LabLoad = scene.data.load
proc seed*(scene: LabScene): uint32 = scene.data.seed
proc sizeScale*(scene: LabScene): float64 = scene.data.sizeScale
proc opacity*(scene: LabScene): float64 = scene.data.opacity

proc triangle(radius: float64): PathData =
  let builder = newPathBuilder()
  builder.moveTo(vec2(0,-radius))
  builder.lineTo(vec2(radius,radius))
  builder.lineTo(vec2(-radius,radius))
  builder.closePath()
  builder.finishPath()

proc sampled(scene: LabScene, index: int, cursor: float64): LabItem =
  result = scene.data.items[index]
  case scene.load
  of LabLoad.staticFrame: discard
  of LabLoad.properties:
    let angle = cursor * 2 * PI
    result.translation = result.translation + vec2(sin(angle)*result.radius*0.5, cos(angle)*result.radius*0.5)
    result.rotation = (cursor*360).deg
    # Geometry/path storage remains unchanged; alpha is fixed for this scene.
    result.fill = Color(r: 0.25+0.5*cursor, g: 0.8-0.4*cursor,
      b: 0.6, a: scene.opacity)
  of LabLoad.geometry:
    let factor = 0.75+0.25*sin(cursor*2*PI)
    result.radius *= factor
    result.size = result.size * factor
    if result.kind == DrawKind.path: result.path = triangle(result.radius)

iterator sampledItems*(scene: LabScene, cursor: float64): LabItem =
  ## Yield values, never the mutable private seq or a mutable reference into it.
  requireCursor(cursor)
  for index in 0..<scene.objectCount: yield scene.sampled(index,cursor)

proc appendItem(builder: CanvasBuilder, item: LabItem) =
  builder.beginGroup(groupTransform(translate=item.translation, rotate=item.rotation))
  let ink = paint(fill=some(item.fill))
  case item.kind
  of DrawKind.circle: builder.addCircle(vec2(0,0),item.radius,ink)
  of DrawKind.rectangle: builder.addRect(item.size * -0.5,item.size,paint=ink)
  of DrawKind.path: builder.addPath(item.path,ink)
  else: raise newException(LabError,"unexpected workload primitive")
  builder.endGroup()

proc drawItems(scene: LabScene, cursor: float64): CanvasFrame =
  let builder = newCanvasBuilder(some(vec2(LabViewWidth,LabViewHeight)), color("#101820"))
  for item in scene.sampledItems(cursor): builder.appendItem(item)
  builder.finishFrame()

proc sampleIntoInternal*(scene: LabScene, cursor: float64, items: var seq[LabItem]) =
  ## Producer-owned fixed capacity. No alias to SceneStorage and no resizing.
  requireCursor(cursor)
  if items.len != scene.objectCount: raise newException(LabError,"producer item capacity differs")
  for index in 0..<items.len: items[index] = scene.sampled(index,cursor)

proc frameFromItemsInternal*(scene: LabScene, items: openArray[LabItem]): CanvasFrame =
  ## Separate item/geometry sampling from builder sealing, using the same commands.
  if items.len != scene.objectCount: raise newException(LabError,"producer item capacity differs")
  let builder = newCanvasBuilder(some(vec2(LabViewWidth,LabViewHeight)), color("#101820"))
  for item in items: builder.appendItem(item)
  builder.finishFrame()

proc newLabScene*(count=16, load=LabLoad.properties, seed=LabSeed,
    sizeScale=1.0, opacity=0.85): LabScene =
  if count notin 1..10000: raise newException(LabError,"object count must be in 1..10000")
  if not finite(sizeScale) or sizeScale < 0.5 or sizeScale > 2:
    raise newException(LabError,"size scale must be in 0.5..2")
  if not finite(opacity) or opacity < 0 or opacity > 1:
    raise newException(LabError,"opacity must be in 0..1")
  let columns = int(ceil(sqrt(float64(count)*LabViewWidth/LabViewHeight)))
  let rows = (count+columns-1) div columns
  let cell = vec2(LabViewWidth/columns, LabViewHeight/rows)
  result.data = SceneStorage(load:load,seed:seed,sizeScale:sizeScale,opacity:opacity,
    items:newSeq[LabItem](count))
  var rng = seed
  for index in 0..<count:
    rng = rng*1664525'u32+1013904223'u32
    let jitterX = (float64(rng and 255)/255-0.5)*cell.x*0.15
    rng = rng*1664525'u32+1013904223'u32
    let jitterY = (float64(rng and 255)/255-0.5)*cell.y*0.15
    let radius = min(cell.x,cell.y)*0.2*sizeScale
    var item = LabItem(id:index, kind: [DrawKind.circle,DrawKind.rectangle,DrawKind.path][index mod 3],
      translation:vec2((float64(index mod columns)+0.5)*cell.x+jitterX,
        (float64(index div columns)+0.5)*cell.y+jitterY),
      radius:radius,size:vec2(radius*1.6,radius*1.6),
      fill:Color(r:0.25,g:0.8,b:0.6,a:opacity))
    if item.kind == DrawKind.path: item.path = triangle(radius)
    result.data.items[index] = item
  result.data.fixed = result.drawItems(0)

proc frameAt*(scene: LabScene, cursor: float64): CanvasFrame =
  requireCursor(cursor)
  if scene.load == LabLoad.staticFrame: scene.data.fixed else: scene.drawItems(cursor)

proc parseCursor*(percent: string): float64 =
  ## Invalid editing text must not reach an animation control.
  var value: float64
  try: value = parseFloat(percent.strip)
  except ValueError: raise newException(LabError,"enter a percentage in 0..100")
  # Validate before normalization: a tiny negative may divide to signed zero.
  if not finite(value) or value < 0 or value > 100:
    raise newException(LabError,"enter a percentage in 0..100")
  result = value/100

proc steppedCursor*(cursor: float64, delta=1.0/120): float64 =
  requireCursor(cursor)
  if not finite(delta): raise newException(LabError,"step must be finite")
  max(0.0,min(1.0,cursor+delta))

proc reconfigured*(scene: LabScene, count=0, load=none(LabLoad),
    sizeDelta=0.0, opacityDelta=0.0): LabScene =
  newLabScene(count=(if count==0:scene.objectCount else:count),
    load=load.get(scene.load), seed=scene.seed,
    sizeScale=max(0.5,min(2.0,scene.sizeScale+sizeDelta)),
    opacity=max(0.0,min(1.0,scene.opacity+opacityDelta)))
