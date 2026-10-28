## Pure accepted-target/presentation values. Publication belongs exclusively to
## ManagedDriver's existing State/Host attempt; this module owns no registry.
import std/[options, tables]
import ./[graphics, animation]

type
  PropertyTrack = object
    anchor: float64
    anchored: bool
    case property: CanvasProperty
    of CanvasProperty.position, CanvasProperty.center, CanvasProperty.size,
        CanvasProperty.translate, CanvasProperty.scale:
      vector: Transition[Vec2]
    of CanvasProperty.radius, CanvasProperty.strokeWidth, CanvasProperty.rotate:
      scalar: Transition[float64]
    of CanvasProperty.fill, CanvasProperty.stroke:
      rgba: Transition[Color]
  ElementTracks = object
    definition: CanvasTransitionDefinition
    kind: DrawKind
    tracks: seq[PropertyTrack]
  CanvasPresentationInternal* = object
    target, frame: CanvasFrame
    elements: seq[ElementTracks]
    reduced: bool

proc active(track: PropertyTrack): bool =
  case track.property
  of CanvasProperty.position, CanvasProperty.center, CanvasProperty.size,
      CanvasProperty.translate, CanvasProperty.scale: track.vector.active
  of CanvasProperty.radius, CanvasProperty.strokeWidth, CanvasProperty.rotate: track.scalar.active
  of CanvasProperty.fill, CanvasProperty.stroke: track.rgba.active

proc active*(presentation: CanvasPresentationInternal): bool =
  for element in presentation.elements:
    for track in element.tracks:
      if track.active: return true

proc activePropertyCountInternal*(presentation: CanvasPresentationInternal): int =
  for element in presentation.elements:
    for track in element.tracks:
      if track.active: inc result

proc frameInternal*(presentation: CanvasPresentationInternal): CanvasFrame = presentation.frame

proc extraBytesInternal*(presentation: CanvasPresentationInternal): int =
  if presentation.elements.len == 0: return 0
  # Conservative accounting: charge even when the first frame shares target
  # storage. Both the immutable frame and every owned track are bounded.
  result = presentation.frame.ownedBytes
  for element in presentation.elements:
    result += sizeof(ElementTracks) + element.definition.identity.len +
      element.tracks.len * sizeof(PropertyTrack)

proc scalar(command: CanvasCommand, definition: CanvasTransitionDefinition,
    property: CanvasProperty): float64 =
  case property
  of CanvasProperty.radius: command.radius
  of CanvasProperty.strokeWidth: command.paint.strokeWidth
  of CanvasProperty.rotate: float64(definition.rotation)
  else: raise newException(GraphicsError, "not a scalar transition")

proc vector(command: CanvasCommand, definition: CanvasTransitionDefinition,
    property: CanvasProperty): Vec2 =
  case property
  of CanvasProperty.position:
    command.position
  of CanvasProperty.center: command.center
  of CanvasProperty.size: command.size
  of CanvasProperty.translate: definition.translation
  of CanvasProperty.scale: definition.scaling
  else: raise newException(GraphicsError, "not a vector transition")

proc rgba(command: CanvasCommand, property: CanvasProperty): Option[Color] =
  if property == CanvasProperty.fill: command.paint.fill else: command.paint.stroke

proc display(presentation: CanvasPresentationInternal): CanvasFrame =
  if not presentation.active: return presentation.target
  var commands: seq[CanvasCommand]
  for command in presentation.target.commands: commands.add(command)
  for element in presentation.elements:
    let index = element.definition.commandIndex
    var command = commands[index]
    var translation = element.definition.translation
    var rotation = element.definition.rotation
    var scaling = element.definition.scaling
    for track in element.tracks:
      case track.property
      of CanvasProperty.position, CanvasProperty.center, CanvasProperty.size:
        command = command.withCanvasVectorInternal(track.property, track.vector.sample)
      of CanvasProperty.radius, CanvasProperty.strokeWidth:
        command = command.withCanvasScalarInternal(track.property, track.scalar.sample)
      of CanvasProperty.fill, CanvasProperty.stroke:
        command = command.withCanvasColorInternal(track.property, track.rgba.sample)
      of CanvasProperty.translate: translation = track.vector.sample
      of CanvasProperty.rotate: rotation = track.scalar.sample.deg
      of CanvasProperty.scale: scaling = track.vector.sample
    if command.kind == DrawKind.beginGroup:
      command = command.withCanvasTransformInternal(translation, rotation, scaling)
    commands[index] = command
  presentation.target.replaceCanvasCommandsInternal(commands)

proc retargetCanvasPresentationInternal*(previous: CanvasPresentationInternal,
    target: CanvasFrame, reduced: bool, reactivated = false,
    forbidRetarget = false): CanvasPresentationInternal =
  result.target = target
  result.reduced = reduced
  var index: Table[string, int]
  for i, element in previous.elements: index[element.definition.identity] = i
  for definition in target.transitionDefinitionsInternal:
    if definition.properties == {}: continue
    let command = target.commandAt(definition.commandIndex)
    var oldIndex = index.getOrDefault(definition.identity, -1)
    if oldIndex >= 0 and previous.elements[oldIndex].kind != command.kind: oldIndex = -1
    var element = ElementTracks(definition: definition, kind: command.kind)
    for property in definition.properties:
      var oldTrackIndex = -1
      var oldDefinition: CanvasTransitionDefinition
      var oldCommand: CanvasCommand
      if oldIndex >= 0:
        let old = previous.elements[oldIndex]
        oldDefinition = old.definition
        oldCommand = previous.target.commandAt(oldDefinition.commandIndex)
        for i, track in old.tracks:
          if track.property == property: oldTrackIndex = i; break
      let hasOld = oldTrackIndex >= 0
      let configurationChanged = not hasOld or
        oldDefinition.durationMs != definition.durationMs or
        oldDefinition.easingId != definition.easingId or previous.reduced != reduced
      template checkDriver(changed: bool) =
        if hasOld and changed and forbidRetarget:
          raise newException(GraphicsError,
            "a Canvas transition target changed during a tween sampling frame (dual driver)")
      let duration = definition.durationMs.ms
      let easing = Easing(definition.easingId)
      var track: PropertyTrack
      case property
      of CanvasProperty.position, CanvasProperty.center, CanvasProperty.size,
          CanvasProperty.translate, CanvasProperty.scale:
        let goal = vector(command, definition, property)
        let changed = hasOld and vector(oldCommand, oldDefinition, property) != goal
        checkDriver(changed)
        if hasOld: track = previous.elements[oldIndex].tracks[oldTrackIndex]
        else: track = PropertyTrack(property: property)
        if configurationChanged:
          let initial = if hasOld: track.vector.sample else: goal
          track.vector = newTransition(initial, duration, easing, reduced)
        if changed or configurationChanged: track.vector.retarget(goal); track.anchored = false
      of CanvasProperty.radius, CanvasProperty.strokeWidth, CanvasProperty.rotate:
        let goal = scalar(command, definition, property)
        let changed = hasOld and scalar(oldCommand, oldDefinition, property) != goal
        checkDriver(changed)
        if hasOld: track = previous.elements[oldIndex].tracks[oldTrackIndex]
        else: track = PropertyTrack(property: property)
        if configurationChanged:
          let initial = if hasOld: track.scalar.sample else: goal
          track.scalar = newTransition(initial, duration, easing, reduced)
        if changed or configurationChanged: track.scalar.retarget(goal); track.anchored = false
      of CanvasProperty.fill, CanvasProperty.stroke:
        let goal = rgba(command, property)
        if goal.isNone: continue
        let changed = hasOld and rgba(oldCommand, property) != goal
        checkDriver(changed)
        if hasOld: track = previous.elements[oldIndex].tracks[oldTrackIndex]
        else: track = PropertyTrack(property: property)
        if configurationChanged:
          let initial = if hasOld: track.rgba.sample else: goal.get
          track.rgba = newTransition(initial, duration, easing, reduced)
        if changed or configurationChanged: track.rgba.retarget(goal.get); track.anchored = false
      if reactivated: track.anchored = false
      element.tracks.add(track)
    result.elements.add(element)
  result.frame = result.display

proc advanceCanvasPresentationInternal*(previous: CanvasPresentationInternal,
    activeMs: float64): CanvasPresentationInternal =
  result.target = previous.target
  result.reduced = previous.reduced
  for source in previous.elements:
    var element = ElementTracks(definition: source.definition, kind: source.kind)
    for old in source.tracks:
      var track = old
      if track.active:
        let delta = if track.anchored: max(0.0, activeMs - track.anchor) else: 0.0
        case track.property
        of CanvasProperty.position, CanvasProperty.center, CanvasProperty.size,
            CanvasProperty.translate, CanvasProperty.scale: track.vector.advance(delta.ms)
        of CanvasProperty.radius, CanvasProperty.strokeWidth, CanvasProperty.rotate: track.scalar.advance(delta.ms)
        of CanvasProperty.fill, CanvasProperty.stroke: track.rgba.advance(delta.ms)
        track.anchor = activeMs
        track.anchored = true
      element.tracks.add(track)
    result.elements.add(element)
  result.frame = result.display
