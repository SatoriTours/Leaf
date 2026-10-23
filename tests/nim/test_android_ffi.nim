import std/unittest
import leaf/[core, components, component_description, widgets, managed_runtime]
import leaf/backends/android/ffi

var calls: array[8,int]
var failDispose: bool
proc command(context: pointer, tag: uint32, data: ptr uint8, length: csize_t,
             width, height: cdouble, measured: ptr cdouble): int32 {.cdecl, raises:[].} =
  if tag > 7: return 1
  inc calls[tag]
  if tag == 1:
    let output = cast[ptr UncheckedArray[cdouble]](measured)
    output[0] = 100; output[1] = 40
  if tag == 7 and failDispose: return 1
  0

var startupCleanup: Runtime
var factories: int
proc application(): Application =
  if startupCleanup != nil:
    let error = newException(RuntimeCleanupError,"startup cleanup failure")
    error.cleanupRuntime = startupCleanup
    raise error
  inc factories
  let Page = defineComponent[int,int]("AbiPage",proc(ctx: MountContext,p:int):int = 0,
    proc(ctx:ComponentContext,p:int,s:int):UiDescription = host(text("中文😀")))
  componentApplication(component(Page,0),"ABI",400,600)

suite "Android guarded owner ABI":
  test "one opaque owner survives detached views; stale IDs cannot close another Runtime":
    registerAndroidApplication(application)
    var id, mount: uint64
    var callbacks = AndroidCallbacks(abiVersion:1, structSize:uint32(sizeof(AndroidCallbacks)), command:command)
    check leaf_android_create(addr callbacks,addr id) == 0 and id != 0
    check leaf_android_attach(id,400,600,1,addr mount) == 0 and mount != 0
    check leaf_android_phase(id,mount,AndroidResume) == 0
    check leaf_android_phase(id,mount,AndroidTurn) == 0
    check leaf_android_phase(id,mount,AndroidDetach) == 0
    let old = mount
    mount = 0
    check leaf_android_attach(id,600,400,1,addr mount) == 0 and mount > old
    check factories == 1
    check leaf_android_phase(id,old,AndroidDetach) == AndroidRejected
    failDispose = true
    check leaf_android_close(id) == AndroidFailure
    failDispose = false
    check leaf_android_close(id) == 0
    check leaf_android_close(id) == AndroidRejected
    check calls[7] == 3 # detach, failed close, successful retry

  test "invalid callbacks and dirty output slots never enter the business factory":
    var callbacks = AndroidCallbacks(abiVersion:6, structSize:uint32(sizeof(AndroidCallbacks)),command:command)
    var id: uint64
    check leaf_android_create(addr callbacks,addr id) == 1 and id == 0
    callbacks.abiVersion = 1
    id = 99
    check leaf_android_create(addr callbacks,addr id) == 1 and id == 99
    check factories == 1

  test "failed creation returns the retained startup cleanup identity":
    let retained = newRuntime(application())
    startupCleanup = retained
    var callbacks = AndroidCallbacks(abiVersion:1, structSize:uint32(sizeof(AndroidCallbacks)),command:command)
    var id: uint64
    check leaf_android_create(addr callbacks,addr id) == AndroidFailure and id != 0
    check not retained.runtimeClosedInternal
    check leaf_android_close(id) == 0
    check retained.runtimeClosedInternal
    startupCleanup = nil
