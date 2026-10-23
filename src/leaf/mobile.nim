## Shared component API and explicit Android factories, without desktop startup.
import ./[core, widgets, height_index, view, routing, components, app_resources]
from ./mobile_host import ApplicationFactory
from ./backends/android/ffi import ResourceApplicationFactory, registerAndroidApplication
export core, widgets, height_index, view, routing, components, app_resources
export ApplicationFactory, ResourceApplicationFactory, registerAndroidApplication
