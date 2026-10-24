## Exercise the actual examples/native_list application, not a second fixture.
## Native EDIT/checkbox/save -> SQLite -> close/reopen -> a fresh native window.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires Windows and leafProtocolProbes".}
import std/[os, tables, options, algorithm, strutils]
import leaf/[core, backend, backend_session, ui_thread, native_layout]
import leaf/backends/win32/[api, host, backend]
import ../../examples/native_list/[store, application]

type TestFailure = object of CatchableError
proc require(ok: bool, why: string) =
  if not ok: raise newException(TestFailure, why)

var children: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  children.add(window)
  BOOL(1)
proc caption(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let value = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), size)
  $value
proc className(window: HWND): string =
  let value = newWideCString(64)
  require(GetClassNameW(window, cast[WidePtr](unsafeAddr value[0]), 64) != 0,
    "GetClassNameW")
  $value
proc control(root: HWND, class, text: string, byText = true): HWND =
  children.setLen(0)
  discard EnumChildWindows(root, collect, 0)
  for window in children:
    if cmpIgnoreCase(className(window), class) == 0 and
        (not byText or caption(window) == text):
      require(result == nil, "ambiguous actual control " & class & "/" & text)
      result = window
  require(result != nil and IsWindowVisible(result) != 0,
    "visible actual control " & class & "/" & text)

proc post(window: HWND, message: UINT, value: WPARAM, name: string) =
  require(IsWindow(window) != 0, name & " live target")
  let ok = PostMessageW(window, message, value, 0)
  echo "post=", name, " target=", cast[uint](window), " result=", ok
  require(ok != 0, name & " PostMessageW")

proc deadline(window: HWND, message: UINT, timer: UINT_PTR,
              time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(97)

proc runWindow(storage: ListStore, reopen: bool) =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(nativeListApp(storage),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  var timer: UINT_PTR
  var ticks, phase: int
  var complete = false
  try:
    h = createHost("Leaf Native List", DipSize(width: 1000, height: 620))
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
      runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    var port, edit, check, save: HWND
    var list = NoHandle
    var source: uint64

    proc rowWindow(index: int): HWND =
      for entity in session.acceptedEntities().values:
        if entity.row.isSome and entity.row.get.itemIndex == index:
          require(entity.row.get.listHandle == list and
            entity.row.get.itemKey == $index and
            entity.row.get.sourceGeneration == source, "typed stable row identity")
          result = win.rowWindowForTest(entity.handle)
          require(result != nil and IsWindow(result) != 0, "real typed row HWND")
          return

    proc checkRows(first, finish: int) =
      var indices: seq[int]
      for entity in session.acceptedEntities().values:
        if entity.row.isSome:
          let binding = entity.row.get
          require(binding.listHandle == list and binding.itemKey == $binding.itemIndex and
            binding.sourceGeneration == source, "no cross-source binding")
          indices.add(binding.itemIndex)
      indices.sort()
      require(indices.len == finish - first, "bounded real rows, including overscan")
      for n, index in indices: require(index == first + n, "contiguous row identity")
      echo "rows=", indices, " source=", source

    proc observe() =
      inc ticks
      echo "window_reopen=", reopen, " tick=", ticks, " phase=", phase
      if phase == 0:
        for entity in session.acceptedEntities().values:
          if entity.kind == NodeKind.virtualList:
            list = entity.handle
            source = entity.list.get.sourceGeneration
        if list == NoHandle: return
        let row = rowWindow(0)
        if row == nil: return
        port = GetParent(row)
        require(GetDpiForWindow(port) == 96, "fixed fixture requires 96 DPI")
        var client: RECT
        require(GetClientRect(port, addr client) != 0 and client.bottom == 480,
          "actual 480px list viewport")
        checkRows(0, 6)
        edit = control(row, "EDIT", "", false)
        check = control(row, "BUTTON", "完成")
        save = control(row, "BUTTON", "保存 0")
        if reopen:
          require(caption(edit) == "x" and SendMessageW(check, 0x00F0, 0, 0) == 1,
            "fresh native window displays the SQLite values")
          complete = true
          h.requestClose()
        else:
          require(caption(edit) == "" and SendMessageW(check, 0x00F0, 0, 0) == 0,
            "initial unsaved defaults")
          discard SetFocus(edit)
          require(GetFocus() == edit, "focus actual native EDIT")
          phase = 1
          post(edit, WM_CHAR, WPARAM(ord('x')), "edit-x")
      elif phase == 1:
        if runtime.find("edit-0").node.text != "x": return
        require(caption(edit) == "x" and storage.loadItem(0) == ListItem(id: 0),
          "native edit enters row State without auto-save")
        phase = 2
        post(check, BM_CLICK, 0, "checkbox")
      elif phase == 2:
        if runtime.find("done-0").node.attributes.getOrDefault("checked") != "true": return
        require(SendMessageW(check, 0x00F0, 0, 0) == 1 and
          storage.loadItem(0) == ListItem(id: 0), "checkbox is not auto-saved")
        phase = 3
        post(save, BM_CLICK, 0, "save")
      elif phase == 3:
        if runtime.find("status-0").node.text != "已保存": return
        require(storage.loadItem(0) == ListItem(id: 0, note: "x", done: true),
          "real Save callback persisted both values under id zero")
        # Release row focus before navigating; do not mistake protected row zero
        # for an unbounded visible range or inject an artificial extra turn.
        discard SetFocus(h.windowHandle)
        require(GetFocus() == h.windowHandle, "focus outside the list")
        phase = 4
        post(port, WM_VSCROLL, WPARAM(SB_BOTTOM), "bottom")
      elif phase == 4:
        let intent = win.listIntentForTest(list)
        if intent.appliedOffset != 959520.0: return
        checkRows(9994, 10000)
        let last = rowWindow(9999)
        require(last != nil and caption(control(last, "EDIT", "", false)) == "末行 中文 😀",
          "actual final row reads its own persisted id")
        require(storage.loadItem(0) == ListItem(id: 0, note: "x", done: true),
          "scrolling does not overwrite the saved first id")
        echo "bottom_offset=", intent.appliedOffset, " row9999=末行 中文 😀"
        complete = true
        h.requestClose()

    h.setSafeTick(proc() =
      require(ticks < 32, "ordinary native turn limit")
      win.safeListTurn()
      observe())
    timer = SetTimer(nil, 0, 10_000, deadline)
    require(timer != 0, "deadline timer")
    let exitCode = h.pump()
    require(exitCode == 0 and complete, "natural pump completed all window phases")
    echo "window_reopen=", reopen, " pump_exit=", exitCode, " ticks=", ticks
  except CatchableError as error: primary = error
  finally:
    if timer != 0: discard KillTimer(nil, timer)
    if h != nil:
      try:
        h.destroyHost()
        require(h.resourcesReleasedInternal(), "host resources released")
      except CatchableError as error: secondary = error
    if secondary == nil:
      try: runtime.closeRuntime()
      except CatchableError as error: secondary = error
  if secondary != nil:
    echo "actual_secondary=", secondary.msg
    if primary == nil: primary = secondary
  if primary != nil: raise primary

proc main(): int =
  try:
    let path = getAppDir() / "native-list-example.sqlite3"
    require(not fileExists(path), "new isolated evidence database")
    let storage = openListStore(path)
    try:
      storage.saveItem(ListItem(id: 9999, note: "末行 中文 😀"))
      runWindow(storage, false)
    finally: storage.close()
    let reopened = openListStore(path)
    try:
      require(reopened.loadItem(0) == ListItem(id: 0, note: "x", done: true),
        "closed/reopened SQLite retains actual native edits by id")
      runWindow(reopened, true)
    finally: reopened.close()
    echo "test_win32_list_example status=PASS-example"
    return 0
  except CatchableError as error:
    echo "actual_primary=", error.msg
    echo "test_win32_list_example status=FAIL-example"
    return 1

when isMainModule: quit(main())
