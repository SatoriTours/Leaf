## Genuine SetScrollInfo hide/show feedback; every seam forwards to Win32.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires real Windows and leafProtocolProbes".}
import std/[tables, options, math]
import leaf/[core, widgets, components, backend, backend_session, ui_thread, native_layout]
import leaf/component_description
import leaf/backends/win32/[api, calls, host, backend, measure]

const Label = "Native wrapped text must follow the actual viewport width and installed system font. Every row has identical text so the independent GDI oracle is shared."
const Padding = 6.0
var renders: int
let RowDef = defineComponent[int, int]("ScrollbarWidthRow",
  proc(ctx: MountContext, index: int): int = index,
  proc(ctx: ComponentContext, index, model: int): UiDescription =
    host(column(@[text(Label, key="label", styles=style({"width":"full"}))],
      key="row", styles=style({"width":"full", "padding":"6"}))))
let PageDef = defineComponent[int, int]("ScrollbarWidthPage",
  proc(ctx: MountContext, value: int): int = value,
  proc(ctx: ComponentContext, value, model: int): UiDescription =
    inc renders
    componentList("list", @["bar-0", "bar-1"],
      proc(index: int): UiDescription = component(RowDef, index),
      rowHeight=0.0, estimatedHeight=100.0, overscan=0,
      styles=style({"height":"180"})))
proc require(ok: bool, message: string) =
  if not ok: raise newException(UiError, message)
proc widthOf(window: HWND): int32 =
  var r: RECT
  require(GetClientRect(window,addr r) != 0,"actual client rect")
  r.right-r.left
proc oracle(window: HWND, font: HFONT, width: int32): int32 =
  let dc=GetDC(window)
  require(dc != nil,"oracle DC")
  let old=SelectObject(dc,cast[HGDIOBJ](font))
  require(old != nil and cast[int](old) != -1,"oracle font")
  try:
    let text=checkedWide(Label)
    var rect=RECT(right:width)
    require(DrawTextW(dc,unsafeAddr text[0],int32(text.len-1),addr rect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX) > 0,"oracle DrawText")
    result=rect.bottom-rect.top
  finally:
    require(SelectObject(dc,old) == cast[HGDIOBJ](font),"oracle restore font")
    require(ReleaseDC(window,dc) != 0,"oracle release DC")
proc main(): int =
  let activity=newUiScopeActivity()
  let rt=newRuntime(guardUiApplication(componentApplication(component(PageDef,0),
    "scrollbar-width",720,360),proc():uint64=uint64(GetCurrentThreadId()),activity))
  var h: Win32Host
  var primary,secondary: ref CatchableError
  var fontWindows: seq[HWND]
  var projections: seq[tuple[window:HWND,before,after:int32]]
  var widths: seq[int32]
  try:
    h=createHost("scrollbar-width",DipSize(width:720,height:360))
    h.setStartupScope(proc():bool=activity.busy or rt.installingUpdate or rt.installingHook)
    var c=systemWin32Calls()
    let realSend=c.send
    c.send=proc(window:HWND,msg:UINT,wp:WPARAM,lp:LPARAM):LRESULT =
      if msg == WM_SETFONT and window notin fontWindows: fontWindows.add(window)
      realSend(window,msg,wp,lp)
    let realBar=c.setScrollInfo
    c.setScrollInfo=proc(window:HWND,bar:int32,info:ptr SCROLLINFO,redraw:BOOL):int32 =
      let before=widthOf(window)
      result=realBar(window,bar,info,redraw)
      projections.add((window,before,widthOf(window)))
    let realDraw=c.drawText
    c.drawText=proc(dc:HDC,text:WidePtr,count:int32,rect:ptr RECT,flags:UINT):int32 =
      widths.add(rect.right-rect.left)
      realDraw(dc,text,count,rect,flags)
    let win=newWin32Backend(h,c)
    let session=win.attachWin32Backend(rt)
    win.bindSession(session)
    h.bindSession(session,proc():bool=activity.busy)
    # First ordinary turn materializes both rows and removes the real bar when
    # measured content fits. Exactly one later turn must reconcile that width.
    projections.setLen(0)
    win.safeListTurn()
    echo "turn1 projections=",projections.len," widths=",widths
    var list: NodeHandle
    var root,port: HWND
    for entity in session.acceptedEntities().values:
      if entity.kind == NodeKind.virtualList: list=entity.handle
      if entity.row.isSome and entity.row.get.itemIndex == 0:
        root=win.rowWindowForTest(entity.handle)
        port=GetParent(root)
    require(list != NoHandle and root != nil and port != nil,"two typed rows materialized")
    var changed=false
    for projection in projections:
      if projection.window == port:
        echo "bar_readback before=",projection.before," after=",projection.after
        if projection.after > projection.before: changed=true
    require(changed,"premise: real scrollbar hides and widens client")
    require(projections.len == 1,"at most one scrollbar projection in first turn")
    let before=win.listFrameForTest(list)
    let revision=rt.acceptedRevision
    let creates=win.diagnostics.creates
    projections.setLen(0); widths.setLen(0)
    win.safeListTurn()
    let after=win.listFrameForTest(list)
    let scale=float64(GetDpiForWindow(port))/96.0
    var labelWindow: HWND
    for window in fontWindows:
      if GetParent(window) == root and GetWindowTextLengthW(window) > 0: labelWindow=window
    require(labelWindow != nil and scale > 0,"actual native label and DPI")
    let expectedWidth=widthOf(port)-int32(round(2*Padding*scale))
    let actualWidth=widthOf(labelWindow)
    let font=cast[HFONT](SendMessageW(labelWindow,WM_GETFONT,0,0))
    let expectedHeight=float64(oracle(labelWindow,font,expectedWidth))/scale+2*Padding
    echo "turn2 projections=",projections.len," widths=",widths,
      " port_px=",widthOf(port)," label_px=",actualWidth," expected_label_px=",expectedWidth,
      " gdi_row_dip=",expectedHeight," rows=",after.acceptedRows
    require(actualWidth == expectedWidth,"next ordinary turn must use post-scrollbar actual client width")
    require(expectedWidth in widths,"production remeasures at corrected native text width")
    require(projections.len == 1,"exactly one correction projection, no apply loop")
    require(after.rowsetReady and after.acceptedRows.len == 2,"coherent complete typed rowset")
    for row in after.acceptedRows:
      require(abs(row.height-expectedHeight) < 0.001,"corrected GDI row height")
    require(after.acceptedSource == before.acceptedSource and rt.acceptedRevision == revision and
      win.diagnostics.creates == creates and renders == 1,"correction is geometry only")
    projections.setLen(0); widths.setLen(0)
    win.safeListTurn()
    echo "turn3 projections=",projections.len," widths=",widths
    require(projections.len == 0 and widths.len == 0,"stable context stops automatic correction")
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
  echo "probe_win32_scrollbar_width status=passed"
  0
when isMainModule: quit(main())
