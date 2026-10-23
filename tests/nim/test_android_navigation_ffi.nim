import std/unittest
import leaf/[core, components, component_description, widgets]
import leaf/backends/android/ffi

var factories: int
proc command(context: pointer, tag: uint32, data: ptr uint8, length: csize_t,
    width, height: cdouble, measured: ptr cdouble): int32 {.cdecl, raises: [].} =
  if tag == 1:
    let output = cast[ptr UncheckedArray[cdouble]](measured)
    output[0] = 100
    output[1] = 40
  0
proc application(): Application =
  inc factories
  let Page = defineComponent[int, int]("NavigationAbi", proc(ctx: MountContext, p: int): int = 0,
    proc(ctx: ComponentContext, p, s: int): UiDescription = host(text("ABI")))
  componentApplication(component(Page, 0), "ABI", 400, 600)

registerAndroidApplication(application)
suite "Android navigation ABI gate":
  test "ABI5 creates an owner and ABI6 does not enter the factory":
    var callbacks = AndroidCallbacks(abiVersion: 5, structSize: uint32(sizeof(AndroidCallbacks)), command: command)
    var owner: uint64
    check leaf_android_create(addr callbacks, addr owner) == 0
    check owner != 0 and factories == 1
    check leaf_android_close(owner) == 0
    callbacks.abiVersion = 6
    owner = 0
    check leaf_android_create(addr callbacks, addr owner) == 1
    check owner == 0 and factories == 1
