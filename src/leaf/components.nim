import ./core
## Managed components opt in explicitly; importing this module loads no desktop.
import ./[component_description,component_view]
# ownsState and the low-level outlet entry remain runtime-internal.
export component_description except ownsState,pageOutlet,outletSpec,PageOutletSpec
export component_view
import ./managed_runtime
export managed_runtime.componentApplication,managed_runtime.updateStats,managed_runtime.invalidateRoot,managed_runtime.listStats
export core.flush,core.batch,core.uiTask
