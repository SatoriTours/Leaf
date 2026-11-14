## Window-local shadcn mode resolution. A nested provider must not silently
## mutate its siblings or another native window. No OS effects occur here.
import std/[options,tables]
import ../[core,backend,native_theme]
import ../ui_contract

proc resolveTheme*(entities:Table[NodeHandle,MountedEntity],
    initialTheme:NativeTheme):NativeTheme =
  result=initialTheme
  var found=false
  for entity in entities.values:
    if entity.props.standardUi.isNone:continue
    let props=entity.props.standardUi.get
    if props.role != UiRole.theme:
      if props.colorMode.isSome:fail("color mode requires a window-root theme")
      continue
    if not initialTheme.isShadcn:fail("runtime standard theme requires a shadcn window")
    if found or entity.parent != NoHandle or entity.kind != NodeKind.column:
      fail("standard theme must be the sole window root")
    if props.colorMode.isNone:fail("standard theme requires a color mode")
    found=true
    result=if props.colorMode.get==UiColorMode.dark:shadcnDark else:shadcnLight
