## r2 bounded Windows probe: the real managed Win32 accept window, including
## native consumer metadata, backend acceptedDelta -> entity.value ->
## EditorState.acceptPreparedModel. Compiled with -d:release --mm:orc
## -d:nimAllocStats -d:leafProtocolProbes by the acceptance controller; not part
## of the normal test_* runner list.
when not defined(windows): {.error: "Win32 accept allocation probe requires Windows".}
import leaf/[core, widgets, components, backend_session, ui_thread, native_layout,
  native_host_adapter]
import leaf/backends/win32/[api, host, backend]

var field: State[string]
let Field = defineComponent[int, State[string]]("AcceptAllocField",
  proc(ctx: MountContext, p: int): State[string] =
    result = ctx.state("initial-value"); field = result,
  proc(ctx: ComponentContext, p: int, s: State[string]): UiDescription =
    host(input(ctx.value(s), key = "field")))

proc main(): int =
  when not (defined(leafProtocolProbes) and defined(nimAllocStats)):
    echo "probe_accept_alloc status=requires-release-alloc-probes"
    return 2
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(
    componentApplication(component(Field, 0), "accept-alloc",
      width = 400, height = 300),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("accept-alloc", DipSize(width: 400, height: 300))
  h.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate)
  let win = newWin32Backend(h)
  let session = win.attachWin32Backend(rt)
  let handle = session.handleFor(rt.find("field").id)
  var failures = 0
  proc checkWindow(label: string) =
    let allocations = nativeAcceptAllocations
    echo label, " accept_allocations=", allocations
    if allocations != 0: inc failures
  # initial attach confirm window
  checkWindow("initial")
  for i in 1 .. 3:
    let dynamic = "dynamic-value-" & $i & "-" & $i & "-payload"
    field.set(dynamic)
    discard rt.flush()
    checkWindow("hot-" & $i)
  # composition conflict: accept a different dynamic value while composing
  observeCompositionForTest(win, handle, "native-composition-text")
  field.set("conflict-value-" & $17 & "-during-composition")
  discard rt.flush()
  checkWindow("composition-conflict")
  if conflictTextForTest(win, handle) != "conflict-value-17-during-composition":
    echo "probe_accept_alloc conflict_missing"
    inc failures
  # same value during composition: no conflict, still no allocations
  field.set("conflict-value-17-during-composition")
  discard rt.flush()
  checkWindow("composition-same")
  if conflictTextForTest(win, handle) != "conflict-value-17-during-composition":
    echo "probe_accept_alloc conflict_not_preserved_for_same_value"
    inc failures
  h.destroyHost()
  if failures == 0:
    echo "probe_accept_alloc status=passed"
    return 0
  echo "probe_accept_alloc status=failed failures=", failures
  1

when isMainModule: quit(main())
