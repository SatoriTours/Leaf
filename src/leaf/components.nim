import ./core
## Public component API: applications are always managed component runtimes.
import ./[component_description,component_view]
# ownsState, outlet internals and owner-accounting hooks stay runtime-internal.
export component_description except ownsState,pageOutlet,outletSpec,PageOutletSpec,
  accountOwnedDescriptionBytes,ownedDescriptionBytes,sealMountContext,lifecycleRegistrationInternal
import ./component_lifecycle
export component_lifecycle
export component_view
import ./component_routing
export component_routing
import ./routing
export routing.Route
import ./managed_runtime
export managed_runtime.componentApplication,managed_runtime.updateStats,managed_runtime.invalidateRoot,managed_runtime.listStats
export core.flush,core.batch,core.uiTask,core.pumpTasks

import ./component_tasks
export component_tasks
