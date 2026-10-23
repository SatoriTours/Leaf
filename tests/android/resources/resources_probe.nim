import leaf/[core, components, component_description, widgets, app_resources, managed_runtime, native_ffi]
import leaf/backends/android/ffi
export native_ffi
var retained: HostResources
var mode, factories, disposals: int
var failDispose: bool
type CleanupDriver = ref object of RuntimeDriver
method closeDeferred(driver:CleanupDriver) =
  doAssert retained.readAsset("binary.bin") == "a\0b"
  if failDispose: fail("fixture retained driver cleanup failure")
  inc disposals
proc application(resources: HostResources): Application =
  retained = resources
  inc factories
  doAssert resources.readAsset("binary.bin") == "a\0b"
  doAssert resources.dataPath("数据/notes.db").len > 0
  if mode == 1: fail("fixture factory failure")
  let Page = defineComponent[int,int]("ResourcesAbiPage",
    proc(ctx:MountContext,p:int):int =
      ctx.onDispose(proc(e:LifecycleContext) =
        doAssert resources.readAsset("binary.bin") == "a\0b"
        inc disposals)
      0,
    proc(ctx:ComponentContext,p:int,s:int):UiDescription = host(text("Resources")))
  result = componentApplication(component(Page,0),"Resources",400,600)
  if mode == 2:
    let error = newException(RuntimeCleanupError,"fixture retained startup cleanup")
    error.cleanupRuntime = newRuntime(newDriverApplication("Cleanup",400,600,
      proc(owner:Runtime):RuntimeDriver = CleanupDriver()))
    raise error
registerAndroidApplication(application)
proc leaf_resources_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  try:
    case which
    of 0:
      try:
        discard retained.readAsset("binary.bin")
        1
      except CatchableError: 0
    of 1: cint(factories)
    of 2: cint(disposals)
    else: -1
  except Exception: -2
proc leaf_resources_fixture*(nextMode, nextFail:cint) {.exportc,dynlib,cdecl,raises:[].} =
  mode = int(nextMode)
  failDispose = nextFail != 0
