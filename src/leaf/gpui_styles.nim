## Validate the public style vocabulary before GPUI receives a snapshot.
## The vocabulary now lives in `styles.nim`; this bridge keeps its old entry
## point and deliberately does not apply native control-attribute rules.
import ./[core, styles]

proc validateStyles*(root: MountedNode) =
  validateStyleSyntax(root.node.styles)
  for child in root.children:
    validateStyles(child)