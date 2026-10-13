import ./core
## Managed components opt in explicitly; importing this module loads no desktop.
import ./[component_description,component_view]
# ownsState is context validation for the runtime, not part of the public API.
export component_description except ownsState
# Routing exports land in Task 3.
export component_view
import ./managed_runtime
export managed_runtime.componentApplication,managed_runtime.updateStats,managed_runtime.invalidateRoot,managed_runtime.listStats
export core.flush,core.batch,core.uiTask
