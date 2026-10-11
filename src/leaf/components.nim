import ./core
## Managed components opt in explicitly; importing this module loads no desktop.
import ./[component_description,component_view]
export component_description,component_view
import ./managed_runtime
export managed_runtime.componentApplication,managed_runtime.updateStats,managed_runtime.invalidateRoot
export core.flush,core.batch,core.uiTask
