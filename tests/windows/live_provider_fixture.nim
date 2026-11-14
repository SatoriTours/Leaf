## Real HWND/UIA integration fixture, not a Spinner/Alert visual showcase.
when not defined(windows): {.error:"Requires Windows".}
import std/os
import leaf/backends/win32/[api,measure,live_provider]
var context:LiveContext
var providers:array[2,LiveProvider]
var windows:array[2,HWND]
var main:HWND
var failure:string
let stock=paramCount()>0 and paramStr(1)=="--stock"
## Posted wake message: retirement must not wait for the next user input.
const WakeMessage=0x8001'u32
proc window(kind,title:string,x,y,w,h:int32,parent:HWND,style:DWORD,id:int):HWND=
  let cls=checkedWide(kind);let text=checkedWide(title)
  result=CreateWindowExW(0,unsafeAddr cls[0],unsafeAddr text[0],style,x,y,w,h,
    parent,cast[HMENU](id),GetModuleHandleW(nil),nil)
  if result==nil:raise newException(IOError,"CreateWindowExW failed")
proc callback(w:HWND,m:UINT,wp:WPARAM,lp:LPARAM,id:UINT_PTR,data:DWORD_PTR):LRESULT {.stdcall,raises:[].}=
  try:
    if data in 1'u..2'u:
      let i=int(data)-1
      if m==0x003D and cast[int32](lp) == -25 and not stock:
        return providers[i].objectResult(wp,lp)
      if m==WM_NCDESTROY:providers[i].detach()
    if m==WM_COMMAND:
      case int(wp and 0xffff)
      of 10:
        providers[0].stage(LiveKind.status,"Loading next");providers[0].accept()
        discard providers[0].flush()
      of 11:
        providers[0].stage(LiveKind.status,"Loading next");providers[0].accept()
        discard providers[0].flush()
      of 12:
        providers[0].stage(LiveKind.status,"Rejected status");providers[0].discardStage()
        discard providers[0].flush()
      of 13:
        providers[1].stage(LiveKind.alert,"Alert updated. Check details.");providers[1].accept()
        discard providers[1].flush()
      of 14:
        providers[0].detach();discard DestroyWindow(windows[0]);windows[0]=nil
      of 15:
        providers[0].stage(LiveKind.status,"Accepted pending");providers[0].accept()
        providers[0].stage(LiveKind.status,"Rejected pending");providers[0].discardStage()
        discard providers[0].flush()
      of 16:
        providers[0].stage(LiveKind.alert,"Status became alert");providers[0].accept()
        discard providers[0].flush()
      of 99:
        let text=checkedWide("Action invoked")
        discard SendMessageW(cast[HWND](lp),0x000C,0,cast[LPARAM](unsafeAddr text[0]))
      else:discard
      return 0
    if w==main and m==WakeMessage:
      # Bounded safe turn: detach only enqueued; UIA disconnect happens here,
      # outside the synchronous Invoke/WM_COMMAND that retired the binding.
      context.drainRetired()
      echo "wake drain: ",context.counts()
      return 0
    if w==main and m==WM_CLOSE:
      for p in providers:p.detach()
      discard DestroyWindow(w)
      return 0
    if w==main and m==WM_NCDESTROY:PostQuitMessage(0)
  except CatchableError as error:
    failure=error.msg;PostQuitMessage(1)
  DefSubclassProc(w,m,wp,lp)
try:
  context=newLiveContext()
  main=window("STATIC","Leaf live provider contract",100,100,730,460,nil,WS_OVERLAPPEDWINDOW,0)
  if SetWindowSubclass(main,callback,1,0)==0:raise newException(IOError,"Install main subclass")
  context.setWake(main,WakeMessage)
  windows[0]=window("STATIC","Status host",24,24,360,28,main,WS_CHILD or WS_VISIBLE,1)
  windows[1]=window("BUTTON","Alert host",24,64,650,110,main,WS_CHILD or WS_VISIBLE or 7,2)
  for i in 0..1:
    if not stock:
      providers[i]=context.newLiveProvider(windows[i],(if i==0:LiveKind.status else:LiveKind.alert),
        (if i==0:"Loading" else:"Initial alert. Details"))
      providers[i].accept();discard providers[i].flush()
    if SetWindowSubclass(windows[i],callback,1,DWORD_PTR(i+1))==0:raise newException(IOError,"Install live subclass")
  discard window("STATIC","Details",16,24,100,24,windows[1],WS_CHILD or WS_VISIBLE,3)
  discard window("BUTTON","Nested action",130,24,140,30,windows[1],WS_CHILD or WS_VISIBLE or WS_TABSTOP,99)
  discard window("EDIT","draft",290,24,240,30,windows[1],WS_CHILD or WS_VISIBLE or WS_TABSTOP or 0x00800000,4)
  for i,title in ["Update status","Same status","Rejected status","Update alert","Remove status","Coalesced status","Switch kind"]:
    discard window("BUTTON",title,24+int32(i mod 3)*220,200+int32(i div 3)*48,200,32,main,
      WS_CHILD or WS_VISIBLE or WS_TABSTOP,10+i)
  discard ShowWindow(main,5)
  var message:MSG
  while true:
    let result=GetMessageW(addr message,nil,0,0)
    if result<=0:break
    if IsDialogMessageW(main,addr message)==0:
      discard TranslateMessage(addr message);discard DispatchMessageW(addr message)
finally:
  for p in providers:p.detach()
  if main!=nil and IsWindow(main)!=0:discard DestroyWindow(main)
  context.drainRetired()
  echo "provider counts before context close: ",context.counts()
  context.close()
if failure.len>0:quit(failure,1)
