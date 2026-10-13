import ./core
## Managed components opt in explicitly; importing this module loads no desktop.
import ./[component_description,component_view]
# ownsState, outlet internals and owner-accounting hooks stay runtime-internal.
export component_description except ownsState,pageOutlet,outletSpec,PageOutletSpec,
  accountOwnedDescriptionBytes,ownedDescriptionBytes,sealMountContext
export component_view
import ./component_routing
export component_routing
import ./routing
export routing.Route
import ./managed_runtime
export managed_runtime.componentApplication,managed_runtime.updateStats,managed_runtime.invalidateRoot,managed_runtime.listStats
export core.flush,core.batch,core.uiTask
