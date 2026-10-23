## Native scrollbar/client-size transitions with synthetic measured heights.
## Tests the bounded correction policy, not natural GDI/row measurement.
when not defined(windows): {.error: "Requires real Windows".}
import leaf/[core, backend, native_layout]
import leaf/backends/win32/[api, calls, host, list_host, measure]

proc require(ok: bool, message: string) =
  if not ok: raise newException(UiError,message)
proc client(window: HWND): DipSize =
  var rect: RECT
  require(GetClientRect(window,addr rect) != 0,"actual client rect")
  let scale=float64(GetDpiForWindow(window))/96.0
  require(scale > 0,"actual DPI")
  DipSize(width:float64(rect.right-rect.left)/scale,
    height:float64(rect.bottom-rect.top)/scale)
proc main(): int =
  var h: Win32Host
  var port: HWND
  var primary,secondary: ref CatchableError
  try:
    h=createHost("scrollbar-cycle-policy",DipSize(width:720,height:360))
    let cls=checkedWide("STATIC")
    port=CreateWindowExW(0,unsafeAddr cls[0],nil,WS_CHILD or WS_VISIBLE or WS_VSCROLL,
      0,0,720,180,h.windowHandle,nil,GetModuleHandleW(nil),nil)
    require(port != nil,"native viewport creation")
    let props=HostListProps(heightMode:HostHeightMode.variable, itemCount:2,
      estimate:100.0,sourceGeneration:1)
    let list=newListHost(NodeHandle(1),port,props,systemWin32Calls())
    var wakes=0
    list.wake=proc()=inc wakes
    let dpi=int32(GetDpiForWindow(port))
    # First establish a real wide/no-bar client using a fitting projection.
    let initial=client(port)
    let fit=list.prepareFrame(props,initial.width,initial.height,dpi,0,@[],1,0)
    fit.measureRow(0,42);fit.measureRow(1,42);fit.refreshRange();fit.projectBar()
    list.syncScrollbarFrame(fit)
    let wide=client(port)
    require(wide.width > initial.width,"real bar hide widens viewport")
    # Synthetic adversarial sizing: wide -> tall (show), narrow -> short (hide).
    # Both transitions are actual SetScrollInfo/GetClientRect, no fake widths.
    let tall=list.prepareFrame(props,wide.width,wide.height,dpi,0,@[],2,0)
    tall.measureRow(0,100);tall.measureRow(1,100);tall.refreshRange();tall.projectBar()
    list.syncScrollbarFrame(tall)
    let narrow=client(port)
    require(narrow.width < wide.width,"real bar show narrows viewport")
    list.noteClientReadback(tall,narrow.width,narrow.height)
    require(tall.contextPending and wakes == 1,"one pending correction wake")
    list.preparedFrame=tall;list.publishPreparedFrame()
    list.beginGeometryTurn()
    require(list.correctionDue,"next ordinary turn correction due")
    let short=list.prepareFrame(props,narrow.width,narrow.height,dpi,0,@[],3,0)
    short.measureRow(0,42);short.measureRow(1,42);short.refreshRange();short.projectBar()
    list.syncScrollbarFrame(short)
    let returned=client(port)
    require(returned == wide,"real client returns to A in A-B-A")
    var rejected=false
    try: list.noteClientReadback(short,returned.width,returned.height)
    except ListGeometryConvergenceError: rejected=true
    require(rejected,"same-source/intent two-state geometry must report nonconvergence")
    require(list.acceptedFrame == tall and tall.clientWidth == wide.width and
      tall.postClientWidth == narrow.width,"accepted frame unchanged on rejection")
    require(wakes == 1,"cycle rejection queues no further correction")
    list.beginGeometryTurn()
    require(not list.correctionDue and list.correctionBlocked,"automatic correction stopped")
    echo "cycle actual_widths=",wide.width,"->",narrow.width,"->",returned.width,
      " synthetic_heights=100/42 rejected=",rejected," wakes=",wakes," stopped=",list.correctionBlocked
  except CatchableError as error: primary=error
  if port != nil:
    if DestroyWindow(port) == 0: secondary=newException(UiError,"DestroyWindow viewport")
  if h != nil:
    try: h.destroyHost()
    except CatchableError as error: secondary=error
    if not h.resourcesReleasedInternal() and secondary == nil:
      secondary=newException(UiError,"host cleanup incomplete")
  if primary != nil: echo "primary: ",primary.name," ",primary.msg
  if secondary != nil: echo "secondary: ",secondary.name," ",secondary.msg
  if primary != nil or secondary != nil: return 1
  echo "probe_win32_scrollbar_cycle status=passed"
  0
when isMainModule: quit(main())
