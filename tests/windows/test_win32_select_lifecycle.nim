when not defined(windows): {.error: "Native Select lifecycle tests require Windows".}
import std/[unittest, options, times, monotimes]
import std/typedthreads
import leaf
import ../fixture_app
import leaf/[ui_thread, native_layout, styles, backend_session, native_theme]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, calls, select_host, select_provider]
import leaf/ui as standard

type
  LifecycleState = ref object
    value: string
    open: bool
    commits: int
  Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession, runtime: Runtime]

# One reader thread, driven only through the provider's real read guard.
var readerNative {.global.}: pointer
var readerLength {.global.}: int
var readerDone {.global.}: bool

proc readerMain() {.thread.} =
  ## Runs the real Value read path (readGuardEnter -> copy -> readGuardExit).
  ## Only a raw provider pointer crosses the thread boundary.
  readerLength = probeMeasureValueRaw(readerNative)
  readerDone = true

var nativeA {.global.}: pointer
var lengthA {.global.}: int
var doneA {.global.}: bool
var nativeB {.global.}: pointer
var lengthB {.global.}: int
var doneB {.global.}: bool

var peerNative {.global.}: pointer
var readerNavigate {.global.}: int
var donePeer {.global.}: bool
var popupIdentityOld {.global.}: int64
var popupAddressOld {.global.}: int

proc peerReader() {.thread.} =
  readerNavigate = probeNavigateChildRaw(peerNative)
  donePeer = true

proc readerA() {.thread.} =
  lengthA = probeMeasureValueRaw(nativeA)
  doneA = true

proc readerB() {.thread.} =
  lengthB = probeMeasureValueRaw(nativeB)
  doneB = true

proc mounted(build: FixtureBuild): Fixture =
  let activity = newUiScopeActivity()
  let app = fixtureApplication(build, "Select lifecycle", 520, 420)
    .withNativeTheme(shadcnLight)
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost(app.title, DipSize(width: 520, height: 420), theme = shadcnLight)
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
    runtime.installingHook)
  let win = newWin32Backend(h)
  let session = win.attachWin32Backend(runtime, protocol.strict)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

proc handleOf(f: Fixture, key: string): NodeHandle =
  f.s.handleFor(f.runtime.find(key).id)

proc settle(f: Fixture) =
  f.win.safeListTurn()
  discard f.runtime.refresh()
  f.win.safeListTurn()

proc page(state: LifecycleState): Node =
  ## Labels have distinct lengths (1/2/3) so the reader can prove it saw the
  ## snapshot it acquired instead of the newly published one.
  standard.theme(UiColorMode.light, column(@[
    standard.select(
      standard.selectTrigger(placeholder = "选择", key = "colour-trigger"),
      standard.selectContent(@[
        standard.selectItem("a", "A"),
        standard.selectItem("b", "BB"),
        standard.selectItem("c", "CCC")]),
      value = state.value, open = state.open, key = "colour", label = "颜色",
      onChange = proc(e: Event) =
        inc state.commits
        state.value = e.value,
      onOpenChange = proc(e: Event) = state.open = e.open),
    standard.button("外侧", key = "outside")], key = "root"), key = "theme")

proc close(f: Fixture) =
  f.h.destroyHost()
  f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows == 0
  check f.win.diagnostics.liveSelects == 0

suite "select provider snapshot lifecycle":
  test "a paused reader keeps its snapshot alive and publish never waits for it":
    let state = LifecycleState(value: "a")
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let host = f.win.selectHostForTest(f.handleOf("colour"))
      check host != nil
      let provider = host.provider
      check provider != nil
      # Accepted value is "A" (label length 1).
      check provider.probeMeasureValue() == 1
      # Server-side refusal: the provider itself returns UIA_E_NOTSUPPORTED.
      check provider.probeSetValue() == cast[int32](0x80040204'u32)
      let before = provider.probeCounts()
      provider.probeArm()
      readerNative = provider.probeNativePointer()
      readerLength = -1
      readerDone = false
      var reader: Thread[void]
      createThread(reader, readerMain)
      # The real read path is now paused inside readGuardEnter, holding the
      # snapshot that was published before the next publish.
      check provider.probeWaitEntered(3000)
      check not readerDone
      let started = getMonoTime()
      state.value = "b"
      f.settle()
      let elapsedMs = (getMonoTime() - started).inMilliseconds
      # Publish must not block on the reader.
      check elapsedMs < 2000
      let during = provider.probeCounts()
      check during.readers == 1
      # The snapshot the reader holds must still be allocated: the owner retires
      # it and reclaims only after the reader leaves.
      check during.live >= before.live + 1
      # Owner-side queries see the new accepted value while the reader is held.
      check provider.probeMeasureValue() == 2
      provider.probeRelease()
      joinThread(reader)
      check readerDone
      # The reader observed the snapshot it acquired, intact (label "A"), never
      # the newer one and never freed memory.
      check readerLength == 1
      check provider.probeCounts().readers == 0
      # The next publish reclaims the retired snapshot now that no reader holds it.
      state.value = "c"
      f.settle()
      let after = provider.probeCounts()
      check after.live <= during.live - 1
      check provider.probeMeasureValue() == 3
      # The item navigation path is protected too: open the popup and navigate
      # from its root to the first item and back to the parent.
      state.open = true
      f.settle()
      check host.isVisible
      let popup = host.popupProvider
      check popup != nil
      check popup.probeNavigateChild()
      state.open = false
      f.settle()
    finally:
      f.close()
      # Every snapshot of this suite is reclaimed; nothing accumulates.
      check probeCounts(nil).live == 0

  test "a reader exit never frees the retired chain a later reader still holds":
    let state = LifecycleState(value: "a")
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let host = f.win.selectHostForTest(f.handleOf("colour"))
      let provider = host.provider
      check provider != nil
      check provider.probeMeasureValue() == 1
      # R1 reads and exits. Both its exit path and any reclamation window are
      # controllable, so the interleaving below is deterministic.
      provider.probeArmExit()
      provider.probeArmDrain()
      nativeA = provider.probeNativePointer()
      lengthA = -1
      doneA = false
      var first: Thread[void]
      createThread(first, readerA)
      check provider.probeWaitExit(3000)          # R1 dropped its count to 0
      provider.probeReleaseExit()
      # Owner-only design: R1 finishes without touching the retired chain.
      # Reader-drains design: R1 pauses inside the reclamation window instead.
      let readerDrains = provider.probeWaitDrain(700)
      if not readerDrains:
        provider.probeReleaseDrain()              # disarm for the owner
      # R2 enters and acquires the current snapshot in both variants.
      provider.probeArm()
      nativeB = provider.probeNativePointer()
      lengthB = -1
      doneB = false
      var second: Thread[void]
      createThread(second, readerB)
      check provider.probeWaitEntered(3000)
      check not doneB
      let before = provider.probeCounts()
      check before.readers == 1
      # The owner publishes while R1 may still be inside its reclamation window
      # and R2 holds the replaced snapshot.
      state.value = "b"
      f.settle()
      let during = provider.probeCounts()
      check during.live >= before.live + 1
      if readerDrains:
        # Old design: R1 now unhooks and frees the chain it observed as safe.
        provider.probeReleaseDrain()
      joinThread(first)
      check doneA
      let afterExit = provider.probeCounts()
      # Whatever R1 did, only the owner may release retired snapshots, and R2
      # still holds one of them.
      check afterExit.live == during.live
      check afterExit.readers == 1
      check not doneB
      # R2 resumes with exactly the snapshot it acquired (label length 1).
      provider.probeRelease()
      joinThread(second)
      check lengthB == 1
      check provider.probeCounts().readers == 0
      # The owner reclaims in an ordinary turn - no further publish is needed.
      let reclaimBefore = provider.probeCounts()
      let reclaimPublish = probePublishCounts()
      let reclaimGeneration = provider.generation
      f.win.safeListTurn()
      let reclaimAfter = provider.probeCounts()
      let reclaimPublishAfter = probePublishCounts()
      echo "STRICT reclaimsDelta=", reclaimPublishAfter.reclaims - reclaimPublish.reclaims,
        " publishedDelta=", reclaimPublishAfter.published - reclaimPublish.published,
        " allocDelta=", reclaimAfter.allocated - reclaimBefore.allocated,
        " genDelta=", provider.generation - reclaimGeneration
      check reclaimPublishAfter.reclaims > reclaimPublish.reclaims
      check reclaimPublishAfter.published == reclaimPublish.published
      check reclaimAfter.allocated == reclaimBefore.allocated
      check provider.generation == reclaimGeneration
      check reclaimAfter.live <= afterExit.live - 1
      check provider.probeMeasureValue() == 2
    finally:
      f.close()
      check probeCounts(nil).live == 0

  test "a peer detached while another thread navigates is never used after release":
    let state = LifecycleState(value: "a")
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let host = f.win.selectHostForTest(f.handleOf("colour"))
      let triggerProvider = host.provider
      check triggerProvider != nil
      state.open = true
      f.settle()
      check host.isVisible
      let popupProvider = host.popupProvider
      check popupProvider != nil
      # Logical identity, never the heap address: the allocator may legally
      # reuse a freed address for the next provider object.
      popupIdentityOld = popupProvider.probeIdentity()
      popupAddressOld = cast[int](popupProvider.probeNativePointer())   # diagnostic only
      check popupIdentityOld != 0
      let freedProvidersBefore = probeFreedProviders()
      # A plain navigation works while the peer is live.
      check triggerProvider.probeNavigateChild()
      # A reader navigates and is paused inside the peer acquisition.
      echo "PEER step1 open+arm"
      triggerProvider.probeArmPeer()
      peerNative = triggerProvider.probeNativePointer()
      readerNavigate = -2
      donePeer = false
      var reader: Thread[void]
      createThread(reader, peerReader)
      check triggerProvider.probeWaitPeer(3000)
      echo "PEER step2 reader suspended"
      # Owner closes the popup: the peer is detached and the ordinary turn drains
      # the provider queue, which must not free an object a reader is using.
      state.open = false
      f.settle()
      check host.popupProvider == nil
      # One more ordinary turn consumes the retired provider queue, so the old
      # peer object can really be released while the reader is still suspended.
      f.win.safeListTurn()
      echo "PEER step3 peer retired+released, releasing reader"
      triggerProvider.probeReleasePeer()
      joinThread(reader)
      check donePeer
      echo "PEER step4 reader joined navigate=", readerNavigate, " freedFlag=", triggerProvider.probePeerFreed()
      check triggerProvider.probePeerFreed() == 0
      # After detach a navigation is a legal empty relation, not a stale object.
      check not triggerProvider.probeNavigateChild()
      # The old provider object was really released (retired), and reopening
      # creates a new object with a different LOGICAL identity; its relation and
      # visibility must be correct. The heap address is not an identity.
      check probeFreedProviders() > freedProvidersBefore
      state.open = true
      f.settle()
      check host.popupProvider != nil
      let popupIdentityNew = host.popupProvider.probeIdentity()
      let popupAddressNew = cast[int](host.popupProvider.probeNativePointer())
      echo "PEER identity old=", popupIdentityOld, " new=", popupIdentityNew,
        " sameAddress=", popupAddressOld == popupAddressNew
      check popupIdentityNew != popupIdentityOld
      check host.isVisible
      check triggerProvider.probeNavigateChild()
      check triggerProvider.probePeerFreed() == 0
      state.open = false
      f.settle()
    finally:
      f.close()
      check probeCounts(nil).live == 0

  test "a stable ordinary turn publishes nothing and reclaims retired snapshots":
    let state = LifecycleState(value: "a")
    let f = mounted(proc(): Node = page(state))
    try:
      f.settle()
      let host = f.win.selectHostForTest(f.handleOf("colour"))
      let provider = host.provider
      check provider != nil
      let before = provider.probeCounts()
      let generationBefore = provider.generation
      let publishBefore = probePublishCounts()
      # One ordinary turn with no accepted-state change and no refresh.
      f.win.safeListTurn()
      let after = provider.probeCounts()
      let publishAfter = probePublishCounts()
      echo "STABLE mismatch=", publishAfter.mismatch,
        " publishedDelta=", publishAfter.published - publishBefore.published,
        " reclaimsDelta=", publishAfter.reclaims - publishBefore.reclaims,
        " allocDelta=", after.allocated - before.allocated,
        " freedDelta=", after.freed - before.freed,
        " genDelta=", provider.generation - generationBefore
      check publishAfter.published == publishBefore.published
      check after.allocated == before.allocated
      check provider.generation == generationBefore
      # Retired snapshots are reclaimed by the owner turn with no new publish:
      # the counters stay put and only the retired/live accounting drops.
      state.value = "a"
      f.settle()
      let reclaimBefore = provider.probeCounts()
      let reclaimPublish = probePublishCounts()
      let reclaimGeneration = provider.generation
      f.win.safeListTurn()
      let reclaimAfter = provider.probeCounts()
      let reclaimPublishAfter = probePublishCounts()
      echo "RECLAIM reclaimsDelta=", reclaimPublishAfter.reclaims - reclaimPublish.reclaims,
        " publishedDelta=", reclaimPublishAfter.published - reclaimPublish.published,
        " allocDelta=", reclaimAfter.allocated - reclaimBefore.allocated,
        " genDelta=", provider.generation - reclaimGeneration
      check reclaimPublishAfter.published == reclaimPublish.published
      check reclaimAfter.allocated == reclaimBefore.allocated
      check provider.generation == reclaimGeneration
      # The popup provider follows the same rule: a popup reader holds the old
      # snapshot, the accepted value changes (a real publish retires it), the
      # reader leaves, and the next ordinary turn reclaims without a publish.
      state.open = true
      f.settle()
      let popupProvider = host.popupProvider
      check popupProvider != nil
      popupProvider.probeArm()
      readerNative = popupProvider.probeNativePointer()
      readerLength = -1
      readerDone = false
      var popupReader: Thread[void]
      createThread(popupReader, readerMain)
      check popupProvider.probeWaitEntered(3000)
      state.value = "b"
      f.settle()
      popupProvider.probeRelease()
      joinThread(popupReader)
      # The popup snapshot carries the list name and rows, not the Value field
      # (the read-only value belongs to the trigger), so the measured value is 0.
      check readerLength == 0
      let popupBefore = popupProvider.probeCounts()
      let popupPublish = probePublishCounts()
      let popupGeneration = popupProvider.generation
      f.win.safeListTurn()
      let popupAfter = popupProvider.probeCounts()
      let popupPublishAfter = probePublishCounts()
      echo "POPUP-RECLAIM reclaimsDelta=", popupPublishAfter.reclaims - popupPublish.reclaims,
        " publishedDelta=", popupPublishAfter.published - popupPublish.published,
        " allocDelta=", popupAfter.allocated - popupBefore.allocated,
        " genDelta=", popupProvider.generation - popupGeneration
      check popupPublishAfter.reclaims > popupPublish.reclaims
      check popupPublishAfter.published == popupPublish.published
      check popupAfter.allocated == popupBefore.allocated
      check popupProvider.generation == popupGeneration
    finally:
      f.close()
      check probeCounts(nil).live == 0
