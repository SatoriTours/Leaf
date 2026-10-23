## Actual HWND resize + wrapped native text. Expected heights come from GDI
## using the installed control font, never from the production HeightIndex.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}
import std/[tables, options, math, os, strutils]
import leaf/[core, widgets, components, backend, backend_session, ui_thread, native_layout]
import leaf/component_description
import leaf/backends/win32/[api, calls, host, backend, measure]

const Label = "Native wrapped text must follow the actual viewport width and installed system font. Every row has identical text so the independent GDI oracle is shared."
const Estimate = 24.0
const Padding = 6.0
var keys: seq[string]
var renders: int
let RowDef = defineComponent[int, int]("WidthRow",
  proc(ctx: MountContext, index: int): int = index,
  proc(ctx: ComponentContext, index, model: int): UiDescription =
    host(column(@[text(Label, key="label", styles=style({"width":"full"}))],
      key="row", styles=style({"width":"full", "padding":"6"}))))
let PageDef = defineComponent[int, int]("WidthPage",
  proc(ctx: MountContext, value: int): int = value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    inc renders
    componentList("list", keys,
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight=0.0, estimatedHeight=Estimate, overscan=0,
      styles=style({"height":"180"})))
proc require(ok: bool, message: string) =
  if not ok: raise newException(UiError, message)
proc rectOf(window, parent: HWND): RECT =
  require(GetWindowRect(window, addr result) != 0, "GetWindowRect")
  var points = [POINT(x:result.left,y:result.top), POINT(x:result.right,y:result.bottom)]
  setLastError(0)
  let mapped = MapWindowPoints(nil,parent,addr points[0],2)
  require(mapped != 0 or lastError() == 0, "MapWindowPoints")
  result = RECT(left:points[0].x,top:points[0].y,right:points[1].x,bottom:points[1].y)
proc oracle(window: HWND, font: HFONT, width: int32): int32 =
  let dc = GetDC(window)
  require(dc != nil, "oracle GetDC")
  let old = SelectObject(dc,cast[HGDIOBJ](font))
  require(old != nil and cast[int](old) != -1, "oracle SelectObject")
  try:
    let label = checkedWide(Label)
    var bounds = RECT(right:width)
    require(DrawTextW(dc,unsafeAddr label[0],int32(label.len-1),addr bounds,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX) > 0, "oracle DrawTextW")
    result = bounds.bottom-bounds.top
  finally:
    require(SelectObject(dc,old) == cast[HGDIOBJ](font), "oracle font restore")
    require(ReleaseDC(window,dc) != 0, "oracle ReleaseDC")
proc main(): int =
  for i in 0..<30: keys.add("width-" & $i)
  let activity = newUiScopeActivity()
  let rt = newRuntime(guardUiApplication(componentApplication(component(PageDef,0),
    "variable-width",720,360),proc():uint64=uint64(GetCurrentThreadId()),activity))
  var h: Win32Host
  var primary, secondary: ref CatchableError
  var fontWindows: seq[HWND]
  var drawWidths: seq[int32]
  let mode=if paramCount() == 1: paramStr(1) else: "roundtrip"
  var failWindow: HWND
  var inject, injected: bool
  try:
    h=createHost("variable-width",DipSize(width:720,height:360))
    h.setStartupScope(proc():bool=activity.busy or rt.installingUpdate or rt.installingHook)
    var c=systemWin32Calls()
    let realPos=c.windowPos
    c.windowPos=proc(window,after:HWND,x,y,width,height:int32,flags:UINT):BOOL =
      if inject and window == failWindow:
        inject=false
        injected=true
        setLastError(1234)
        return 0
      realPos(window,after,x,y,width,height,flags)
    let realSend=c.send
    c.send=proc(window:HWND,msg:UINT,wp:WPARAM,lp:LPARAM):LRESULT =
      if msg == WM_SETFONT and window notin fontWindows: fontWindows.add(window)
      realSend(window,msg,wp,lp)
    let realDraw=c.drawText
    c.drawText=proc(dc:HDC,label:WidePtr,count:int32,rect:ptr RECT,flags:UINT):int32 =
      drawWidths.add(rect.right-rect.left)
      realDraw(dc,label,count,rect,flags)
    let win=newWin32Backend(h,c)
    let session=win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session,proc():bool=activity.busy)
    # Fixed schedule: two prime turns, two PageDown events with two turns each,
    # then one ordinary geometry turn per actual width change. No pump/retry.
    win.safeListTurn(); win.safeListTurn()
    var list: NodeHandle
    var port: HWND
    for entity in session.acceptedEntities().values:
      if entity.kind == NodeKind.virtualList: list=entity.handle
      if entity.row.isSome: port=GetParent(win.rowWindowForTest(entity.handle))
    require(list != NoHandle and port != nil,"typed list and viewport")
    let scale=float64(GetDpiForWindow(port))/96.0
    require(scale > 0,"actual viewport DPI")
    let prime=win.listFrameForTest(list)
    require(prime.hasAccepted and prime.rowsetReady and prime.acceptedFirst == 0,
      "prime ready at first row")
    for step in 0..<2:
      discard SendMessageW(port,WM_VSCROLL,WPARAM(SB_PAGEDOWN),0)
      win.safeListTurn(); win.safeListTurn()
    let before=win.listFrameForTest(list)
    require(before.rowsetReady and before.acceptedFirst >= 2,"scroll away from measured row0")
    var firstIndex=high(int)
    var root: HWND
    for entity in session.acceptedEntities().values:
      if entity.row.isSome and entity.row.get.itemIndex < firstIndex:
        firstIndex=entity.row.get.itemIndex
        root=win.rowWindowForTest(entity.handle)
    require(firstIndex >= 1 and root != nil,"offscreen measured prefix premise")
    var labelWindow: HWND
    for window in fontWindows:
      if GetParent(window) == root and GetWindowTextLengthW(window) > 0: labelWindow=window
    require(labelWindow != nil,"actual native text child")
    let font=cast[HFONT](SendMessageW(labelWindow,WM_GETFONT,0,0))
    require(font != nil,"installed WM_GETFONT")
    var fontSpec: LOGFONTW
    require(GetObjectW(cast[HGDIOBJ](font),int32(sizeof(fontSpec)),addr fontSpec) == int32(sizeof(fontSpec)),"actual font LOGFONT")
    let wideRect=rectOf(labelWindow,root)
    let wideHeight=float64(oracle(labelWindow,font,wideRect.right-wideRect.left))/scale+2*Padding
    echo "wide dpi=",GetDpiForWindow(port)," first=",firstIndex," label_px=",wideRect.right-wideRect.left,
      " gdi_row_dip=",wideHeight," font_height=",fontSpec.lfHeight," rows=",before.acceptedRows
    require(wideHeight > Estimate,"old measured height must differ from estimate")
    var oldRects: seq[tuple[window:HWND, rect:RECT]]
    for entity in session.acceptedEntities().values:
      if entity.row.isNone: continue
      let rowWindow=win.rowWindowForTest(entity.handle)
      oldRects.add((rowWindow,rectOf(rowWindow,port)))
      if entity.row.get.itemIndex == firstIndex+1: failWindow=rowWindow
      for window in fontWindows:
        if GetParent(window) == rowWindow:
          oldRects.add((window,rectOf(window,port)))
    var oldBar=SCROLLINFO(cbSize:UINT(sizeof(SCROLLINFO)),fMask:SIF_ALL)
    require(GetScrollInfo(port,SB_VERT,addr oldBar) != 0,"old scrollbar")
    let source=before.acceptedSource
    let revision=rt.acceptedRevision
    let creates=win.diagnostics.creates
    var outer: RECT
    require(GetWindowRect(h.windowHandle,addr outer) != 0,"host outer rect")
    require(SetWindowPos(h.windowHandle,nil,0,0,int32(round(310*scale)),outer.bottom-outer.top,
      SWP_NOZORDER or SWP_NOACTIVATE or 0x0002'u32) != 0,"actual host narrow resize")
    drawWidths.setLen(0)
    if mode == "rollback":
      inject=true
      var failure: string
      try: win.safeListTurn()
      except CatchableError as error: failure=error.msg
      require(injected and failure.contains("1234"),"actual second-row placement rejection")
      let replay=win.listFrameForTest(list)
      require(replay.acceptedToken == before.acceptedToken and replay.acceptedRows == before.acceptedRows and
        replay.acceptedOffset == before.acceptedOffset,"accepted index/offset/token survive width failure")
      for item in oldRects:
        require(rectOf(item.window,port) == item.rect,"all row/text HWND rectangles restored")
      var replayBar=SCROLLINFO(cbSize:UINT(sizeof(SCROLLINFO)),fMask:SIF_ALL)
      require(GetScrollInfo(port,SB_VERT,addr replayBar) != 0 and replayBar.nMin == oldBar.nMin and
        replayBar.nMax == oldBar.nMax and replayBar.nPage == oldBar.nPage and replayBar.nPos == oldBar.nPos,
        "actual scrollbar restored")
      echo "width_failure primary=1234 replay_token=",replay.acceptedToken," prefix=",replay.acceptedRows[0].prefix,
        " restored_rects=",oldRects.len," retry_turns=1"
      # Exactly one later ordinary turn must retry the still-unapplied width.
      win.safeListTurn()
    else:
      require(mode == "roundtrip","known probe mode")
      win.safeListTurn()
    let after=win.listFrameForTest(list)
    let narrowRect=rectOf(labelWindow,root)
    let expected=float64(oracle(labelWindow,font,narrowRect.right-narrowRect.left))/scale+2*Padding
    echo "narrow first=",after.acceptedFirst," offset=",after.acceptedOffset,
      " label_px=",narrowRect.right-narrowRect.left," gdi_row_dip=",expected,
      " draw_widths=",drawWidths," rows=",after.acceptedRows
    require(expected > wideHeight and narrowRect.right-narrowRect.left < wideRect.right-wideRect.left,
      "real narrower text must wrap higher")
    for row in after.acceptedRows:
      require(abs(row.height-expected) < 0.001,"visible row uses GDI wrapped height with padding once")
    require(abs(float64(rectOf(root,port).bottom-rectOf(root,port).top)-expected*scale) <= 1,
      "actual row HWND height matches GDI")
    require(int32(round(float64(narrowRect.right-narrowRect.left))) in drawWidths,
      "production DrawText observed actual child effective width")
    # The earliest typed row has no earlier materialized rows in this attempt.
    # Old offscreen measurements are invalid at the new width: prefix is estimate.
    for row in after.acceptedRows:
      if row.index == firstIndex:
        echo "context_prefix index=",row.index," actual=",row.prefix," expected=",float64(row.index)*Estimate
        require(abs(row.prefix-float64(row.index)*Estimate) < 0.001,
          "width epoch must invalidate offscreen measured HeightIndex entries")
    if mode == "roundtrip":
      require(SetWindowPos(h.windowHandle,nil,0,0,outer.right-outer.left,outer.bottom-outer.top,
        SWP_NOZORDER or SWP_NOACTIVATE or 0x0002'u32) != 0,"actual widen resize")
      PostQuitMessage(0)
      require(h.pump() == 0,"one predetermined host turn to widen")
      let widened=win.listFrameForTest(list)
      require(rectOf(labelWindow,root).right-rectOf(labelWindow,root).left == wideRect.right-wideRect.left,
        "original actual text width restored")
      for row in widened.acceptedRows:
        require(abs(row.height-wideHeight) < 0.001,"widened height uses original GDI oracle")
        if row.index == firstIndex:
          require(abs(row.prefix-float64(row.index)*Estimate) < 0.001,"widen resets offscreen index again")
      require(abs(float64(rectOf(root,port).bottom-rectOf(root,port).top)-wideHeight*scale) <= 1,
        "widened real root height")
      echo "roundtrip width_px=",wideRect.right-wideRect.left," row_dip=",wideHeight," prefix=",widened.acceptedRows[0].prefix
    require(after.acceptedSource == source and rt.acceptedRevision == revision and
      renders == 1 and win.diagnostics.creates == creates,"resize is geometry only with stable typed rows")
  except CatchableError as error: primary=error
  if h != nil:
    try: h.destroyHost()
    except CatchableError as error: secondary=error
    if not h.resourcesReleasedInternal() and secondary == nil:
      secondary=newException(UiError,"host cleanup incomplete")
  if secondary == nil:
    try: rt.closeRuntime()
    except CatchableError as error: secondary=error
  if primary != nil: echo "primary: ",primary.name," ",primary.msg
  if secondary != nil: echo "secondary: ",secondary.name," ",secondary.msg
  if primary != nil or secondary != nil: return 1
  echo "probe_win32_variable_width_boundaries status=passed"
  0
when isMainModule: quit(main())
