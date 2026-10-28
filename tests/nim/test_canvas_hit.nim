import std/[unittest, options]
import leaf/[graphics, canvas_hit]

suite "Canvas hit snapshots":
  test "reverse paint order uses actual geometry and decorations pass through":
    let b = newCanvasBuilder()
    b.addCircle(vec2(0, 0), 10)
    b.addCircle(vec2(0, 0), 5)
    b.addCircle(vec2(0, 0), 20)
    let s = prepareHitSnapshot(b.finishFrame(), @[
      HitBinding(commandIndex: 0, key: "bottom"),
      HitBinding(commandIndex: 1, key: "top")])
    check s.hitTest(vec2(0, 0)).get.target.key == "top"
    check s.hitTest(vec2(8, 0)).get.target.key == "bottom"
    check s.hitTest(vec2(9, 9)).isNone

  test "strokes have holes, rounded corners and flat line end caps":
    let b = newCanvasBuilder()
    let outline = paint(fill = none(Color), stroke = some(color("#ffffff")), strokeWidth = 2)
    b.addCircle(vec2(0, 0), 10, outline)
    b.addRect(vec2(20, 0), vec2(10, 10), radius = 4)
    b.addLine(vec2(40, 0), vec2(50, 0), color("#ffffff"), 4)
    b.addRect(vec2(60, 0), vec2(10, 10), paint = outline)
    let s = prepareHitSnapshot(b.finishFrame(), @[
      HitBinding(commandIndex: 0, key: "ring"), HitBinding(commandIndex: 1, key: "round"),
      HitBinding(commandIndex: 2, key: "line"), HitBinding(commandIndex: 3, key: "outline")])
    check s.hitTest(vec2(0, 0)).isNone
    check s.hitTest(vec2(10.5, 0)).get.target.key == "ring"
    check s.hitTest(vec2(20.1, 0.1)).isNone
    check s.hitTest(vec2(24, 1)).get.target.key == "round"
    check s.hitTest(vec2(45, 1.9)).get.target.key == "line"
    check s.hitTest(vec2(50.1, 0)).isNone
    check s.hitTest(vec2(45, 2.1)).isNone
    check s.hitTest(vec2(65, 5)).isNone
    check s.hitTest(vec2(59.5, -0.5)).get.target.key == "outline"
    check s.hitTest(vec2(61, 5)).isSome # Stroke's inner boundary belongs to it.

  test "group targets inherit child geometry, transformed clips and coordinate maps":
    let b = newCanvasBuilder()
    b.beginGroup(groupTransform(translate = vec2(100, 50), rotate = 90.deg,
      scale = vec2(2, 2)), some(rectangle(0, 0, 10, 10)))
    b.addCircle(vec2(5, 5), 20)
    b.endGroup()
    let s = prepareHitSnapshot(b.finishFrame(), @[HitBinding(commandIndex: 0, key: "group")])
    let h = s.hitTest(vec2(90, 60)).get
    check h.target.key == "group"
    check h.geometryIndex == 1
    check abs(h.target.localPosition.x - 5) < 0.000001
    check abs(h.target.localPosition.y - 5) < 0.000001
    check h.target.position == vec2(90, 60)
    check s.hitTest(vec2(76, 60)).isNone

  test "routes bubble from initial target through interactive groups only":
    let b = newCanvasBuilder()
    b.beginGroup(groupTransform(translate = vec2(10, 0)))
    b.beginGroup(groupTransform(translate = vec2(5, 0)))
    b.addCircle(vec2(0, 0), 4)
    b.endGroup()
    b.endGroup()
    let s = prepareHitSnapshot(b.finishFrame(), @[
      HitBinding(commandIndex: 0, key: "outer"), HitBinding(commandIndex: 1, key: "inner"),
      HitBinding(commandIndex: 2, key: "dot")])
    let h = s.hitTest(vec2(15, 0)).get
    var keys: seq[string]
    for r in h.route: keys.add(r.key)
    check keys == @["dot", "inner", "outer"]
    check h.route[0].position == vec2(0, 0)
    check h.route[1].position == vec2(5, 0)
    check h.route[1].localPosition == vec2(0, 0)
    check h.route[2].position == vec2(15, 0)
    check h.route[2].localPosition == vec2(5, 0)

  test "hitTest false and singular group transforms suppress entire subtrees":
    let b = newCanvasBuilder()
    b.addCircle(vec2(0, 0), 100)
    b.beginGroup()
    b.addCircle(vec2(0, 0), 10)
    b.endGroup()
    b.beginGroup(groupTransform(scale = vec2(0, 1)))
    b.addCircle(vec2(0, 0), 10)
    b.endGroup()
    let s = prepareHitSnapshot(b.finishFrame(), @[
      HitBinding(commandIndex: 0, key: "under"),
      HitBinding(commandIndex: 1, policy: HitPolicy.ignore),
      HitBinding(commandIndex: 2, key: "ignored"),
      HitBinding(commandIndex: 5, key: "singular")])
    check s.hitTest(vec2(0, 0)).get.target.key == "under"

  test "paths and text demand renderer geometry, never a guessed bounding box":
    let p = newPathBuilder()
    p.moveTo(vec2(0, 0)); p.lineTo(vec2(10, 0)); p.lineTo(vec2(0, 10)); p.closePath()
    let b = newCanvasBuilder()
    b.addPath(p.finishPath(), paint())
    let frame = b.finishFrame()
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0, key: "triangle")])
    # Stand-in for the native geometry boundary only; routing uses real frame,
    # matrices and clipping. This does NOT validate Direct2D path containment.
    let s = prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0, key: "triangle")],
      geometryContains = proc(index: int, p: Vec2): bool =
        index == 0 and p.x >= 0 and p.y >= 0 and p.x + p.y <= 10)
    check s.hitTest(vec2(2, 2)).get.target.key == "triangle"
    check s.hitTest(vec2(9, 9)).isNone
    let t = newCanvasBuilder()
    t.addText("中文", vec2(0, 0))
    expect GraphicsError:
      discard prepareHitSnapshot(t.finishFrame(), @[HitBinding(commandIndex: 0, key: "text")])

  test "invalid indices, duplicate sibling identities and quotas reject before use":
    let b = newCanvasBuilder()
    b.addCircle(vec2(0, 0), 2)
    b.addCircle(vec2(10, 0), 2)
    let frame = b.finishFrame()
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 2, key: "missing")])
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0, key: "a"),
        HitBinding(commandIndex: 1, key: "a")])
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0, key: "a"),
        HitBinding(commandIndex: 0, key: "b")])
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0)])
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0, key: "a"),
        HitBinding(commandIndex: 1, key: "b")], maxBindings = 1)
    expect GraphicsError:
      discard prepareHitSnapshot(frame, @[HitBinding(commandIndex: 0, key: "a")], maxBytes = 1)
    expect GraphicsError:
      discard prepareHitSnapshot(default(CanvasFrame), @[])
    let g = newCanvasBuilder()
    g.beginGroup(); g.endGroup()
    expect GraphicsError:
      discard prepareHitSnapshot(g.finishFrame(), @[HitBinding(commandIndex: 1, key: "end")])

  test "identities are scoped to structural parent and snapshot input is owned":
    let b = newCanvasBuilder()
    b.beginGroup()
    b.addCircle(vec2(0, 0), 2)
    b.endGroup()
    b.beginGroup(groupTransform(translate = vec2(10, 0)))
    b.addCircle(vec2(0, 0), 2)
    b.endGroup()
    var bindings = @[HitBinding(commandIndex: 1, key: "dot"), HitBinding(commandIndex: 4, key: "dot")]
    let s = prepareHitSnapshot(b.finishFrame(), bindings)
    bindings[0].key = "changed"
    check s.hitTest(vec2(0, 0)).get.target.key == "dot"
    check s.hitTest(vec2(10, 0)).get.target.commandIndex == 4
    check s.ownedBytes > 0
    check s.hitTest(vec2(Inf, 0)).isNone
