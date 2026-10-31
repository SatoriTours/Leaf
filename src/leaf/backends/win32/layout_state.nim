## Pure Win32 invalidation policy, shared by commit classification and tests.
## Lists keep their transactional geometry path; containers are not opaque leaves.
import std/options
import ../../[core, styles, backend]

proc fixedLeaf*(entity: MountedEntity): bool =
  entity.kind notin {NodeKind.column, NodeKind.row, NodeKind.navigation,
    NodeKind.virtualList} and
    entity.props.layout.width.isSome and entity.props.layout.width.get.kind == dkFixed and
    entity.props.layout.height.isSome and entity.props.layout.height.get.kind == dkFixed

proc layoutAffected*(old, next: MountedEntity): bool =
  if old.kind != next.kind or old.parent != next.parent or old.index != next.index or
      old.props.layout != next.props.layout or old.row != next.row:
    return true
  # Preserve list frame preparation/publication, including source-only changes.
  if next.kind == NodeKind.virtualList: return true
  # relayout also owns Canvas present-before-accept and draw failure rollback.
  # Keep changed frames on that transactional path until drawing is separated
  # from geometry; fixed extents do not make a new scene paint-only here.
  if old.canvas != next.canvas: return true
  # A variant may switch the actual native font role. Decorations stay
  # conservative so future measurement support cannot silently skip layout.
  if old.props.decoration != next.props.decoration or
      old.props.control.variant != next.props.control.variant:
    return true
  if next.fixedLeaf: return false
  case next.kind
  of NodeKind.column, NodeKind.row, NodeKind.navigation, NodeKind.canvasHost,
      NodeKind.progress, NodeKind.spinner, NodeKind.separator:
    false
  else:
    old.props.control.label != next.props.control.label or
      old.props.accessibility.label != next.props.accessibility.label or
      old.props.control.value != next.props.control.value or
      old.props.control.placeholder != next.props.control.placeholder or
      old.props.control.checked != next.props.control.checked or
      old.props.control.enabled != next.props.control.enabled
