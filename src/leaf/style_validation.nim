## Validate public style syntax independently of a native backend's capabilities.
import ./[core, styles]

proc validateStyles*(root: MountedNode) =
  validateStyleSyntax(root.node.styles)
  for child in root.children:
    validateStyles(child)
