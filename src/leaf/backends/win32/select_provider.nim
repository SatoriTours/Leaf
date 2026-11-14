## Dedicated UI Automation provider for the standard select trigger and popup.
##
## Contract: every owner call runs on the HWND owner thread; provider callbacks
## may run on other threads and only read the published snapshot or record one
## bounded request. Publishing and retiring happen in an ordinary native turn,
## never inside a window callback, so business code is never called from COM.
when not defined(windows): {.error:"Native select semantics require Windows".}
import std/[os, strutils, unicode]
import ../../core
import ./api
const Header=(currentSourcePath.parentDir/"select_provider.h").replace('\\','/')
{.compile:"select_provider.c".}
{.passL:"-lole32 -loleaut32".}
when defined(leafProtocolProbes):
  {.passC:"-DLEAF_SELECT_PROVIDER_PROBES".}
type
  NativeContext {.importc:"LeafSelectContext",header:Header,incompleteStruct.}=object
  NativeProvider {.importc:"LeafProvider",header:Header,incompleteStruct.}=object
  NativeItem {.importc:"LeafSelectItem",header:Header,bycopy.}=object
    disabled:cint
    length:cint
    label:ptr uint16
  SelectContext* = ref object
    native:ptr NativeContext
  SelectProvider* = ref object
    native:ptr NativeProvider
  SelectItemState* = object
    label*:string
    disabled*:bool

proc contextNew(outp:ptr ptr NativeContext):int32 {.importc:"leaf_select_context_new",header:Header.}
proc contextSetWake(c:ptr NativeContext,window:pointer,message:uint32):int32 {.importc:"leaf_select_context_set_wake",header:Header.}
proc contextClose(slot:ptr ptr NativeContext):int32 {.importc:"leaf_select_context_close",header:Header.}
proc triggerNew(c:ptr NativeContext,window:pointer,outp:ptr ptr NativeProvider):int32 {.importc:"leaf_select_trigger_new",header:Header.}
proc popupNew(c:ptr NativeContext,window:pointer,outp:ptr ptr NativeProvider):int32 {.importc:"leaf_select_popup_new",header:Header.}
proc linkNative(trigger,popup:ptr NativeProvider):int32 {.importc:"leaf_select_link",header:Header.}
proc stageNative(p:ptr NativeProvider,open,enabled:cint,name,value:ptr uint16,
  items:ptr NativeItem,count,selectedIndex,focused,visible,firstRow,rows,
  rowHeightPx:cint):int32 {.importc:"leaf_select_stage",header:Header.}
proc acceptNative(p:ptr NativeProvider) {.importc:"leaf_select_accept",header:Header,raises:[].}
proc discardNative(p:ptr NativeProvider) {.importc:"leaf_select_discard",header:Header,raises:[].}
proc publishNative(p:ptr NativeProvider,changed:ptr cint):int32 {.importc:"leaf_select_publish",header:Header.}
proc objectNative(p:ptr NativeProvider,wp:uint,lp:int):int {.importc:"leaf_select_get_object",header:Header,raises:[].}
proc detachNative(slot:ptr ptr NativeProvider):int32 {.importc:"leaf_select_detach",header:Header.}
proc drainNative(c:ptr NativeContext):int32 {.importc:"leaf_select_drain",header:Header.}
proc countsNative(c:ptr NativeContext,owned,objects:ptr cint) {.importc:"leaf_select_counts",header:Header.}
proc takeRequestNative(c:ptr NativeContext,window1,window2:pointer,kind,index,
  generation:ptr cint,window:ptr pointer):int32 {.importc:"leaf_select_take_request",header:Header.}
proc clearRequestNative(c:ptr NativeContext) {.importc:"leaf_select_clear_request",header:Header.}
proc traceW*(tag:cstring,window:pointer,lparam:int,wparam:uint) {.importc:"leaf_select_trace_w",header:Header,raises:[].}
proc generationNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_generation",header:Header,raises:[].}
proc windowLiveNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_window_live",header:Header,raises:[].}

proc check(hr:int32,operation:string) =
  if hr<0: fail(operation & " HRESULT 0x" & toHex(cast[uint32](hr),8))

proc utf16(value:string):seq[uint16] =
  ## UTF-16 code units without a terminator: item lengths are explicit.
  for rune in value.runes:
    let code=int(rune)
    if code<=0xffff:
      result.add(uint16(code))
    else:
      let pair=code-0x10000
      result.add(uint16(0xd800+(pair shr 10)))
      result.add(uint16(0xdc00+(pair and 0x3ff)))

proc utf16z(value:string):seq[uint16] =
  ## NUL-terminated copy for name/value, which the C side reads as strings.
  result=utf16(value)
  result.add(0)

proc newSelectContext*():SelectContext =
  result=SelectContext()
  check(contextNew(addr result.native),"Create select provider context")

proc setWake*(c:SelectContext,window:HWND,message:uint32) =
  if c==nil: fail("select provider context is missing")
  check(contextSetWake(c.native,cast[pointer](window),message),"Configure select provider wake")

proc newTrigger*(c:SelectContext,window:HWND):SelectProvider =
  if c==nil or window==nil: fail("select trigger provider requires a context and window")
  result=SelectProvider()
  check(triggerNew(c.native,cast[pointer](window),addr result.native),"Create select trigger provider")

proc newPopup*(c:SelectContext,window:HWND):SelectProvider =
  if c==nil or window==nil: fail("select popup provider requires a context and window")
  result=SelectProvider()
  check(popupNew(c.native,cast[pointer](window),addr result.native),"Create select popup provider")

proc link*(trigger,popup:SelectProvider) =
  if trigger==nil or popup==nil: fail("select providers must both exist")
  check(linkNative(trigger.native,popup.native),"Link select providers")

proc stage*(p:SelectProvider, open, enabled:bool, name, value:string,
    items:openArray[SelectItemState], selectedIndex:int, focused, visible:bool,
    firstRow, rows, rowHeightPx:int) =
  if p==nil: fail("select provider is missing")
  var nameBuffer=utf16z(name)
  var valueBuffer=utf16z(value)
  var labels=newSeq[seq[uint16]](items.len)
  var natives=newSeq[NativeItem](items.len)
  for index,item in items:
    labels[index]=utf16(item.label)
    natives[index].disabled=cint(if item.disabled: 1 else: 0)
    natives[index].length=cint(labels[index].len)
    if labels[index].len>0: natives[index].label=unsafeAddr labels[index][0]
  check(stageNative(p.native,cint(if open: 1 else: 0),
    cint(if enabled: 1 else: 0),
    (if nameBuffer.len==0: nil else: unsafeAddr nameBuffer[0]),
    (if valueBuffer.len==0: nil else: unsafeAddr valueBuffer[0]),
    (if natives.len==0: nil else: addr natives[0]),cint(natives.len),
    cint(selectedIndex),cint(if focused: 1 else: 0),cint(if visible: 1 else: 0),
    cint(firstRow),cint(rows),cint(rowHeightPx)),"Stage select snapshot")

proc accept*(p:SelectProvider) =
  if p!=nil: acceptNative(p.native)

proc discardStage*(p:SelectProvider) =
  if p!=nil: discardNative(p.native)

proc publish*(p:SelectProvider):bool =
  if p==nil: return false
  var changed:cint
  check(publishNative(p.native,addr changed),"Publish select snapshot")
  changed!=0

proc objectResult*(p:SelectProvider,wp:WPARAM,lp:LPARAM):LRESULT =
  if p!=nil: LRESULT(objectNative(p.native,uint(wp),int(lp))) else: 0

proc reclaimNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_reclaim",header:Header.}

proc detach*(p:var SelectProvider) =
  if p==nil: return
  check(detachNative(addr p.native),"Detach select provider")

proc drainRetired*(c:SelectContext) =
  if c!=nil: check(drainNative(c.native),"Drain retired select providers")

proc close*(c:SelectContext) =
  if c!=nil: check(contextClose(addr c.native),"Close select provider context")

proc counts*(c:SelectContext):tuple[owned,objects:int] =
  var owned,objects:cint
  countsNative((if c==nil: nil else: c.native),addr owned,addr objects)
  (int(owned),int(objects))

proc takeRequest*(c:SelectContext, window1, window2:HWND):
    tuple[kind,index,generation:int,window:HWND] =
  if c==nil: return (0,0,0,nil)
  var kind,index,generation:cint
  var window:pointer
  check(takeRequestNative(c.native,cast[pointer](window1),cast[pointer](window2),
    addr kind,addr index,addr generation,addr window),
    "Take select provider request")
  (int(kind),int(index),int(generation),cast[HWND](window))

proc clearRequest*(c:SelectContext) =
  if c!=nil: clearRequestNative(c.native)

proc reclaim*(p:SelectProvider) =
  ## Owner-thread reclamation of retired snapshots (no reader inside).
  if p!=nil: check(reclaimNative(p.native),"Reclaim select snapshots")

proc generation*(p:SelectProvider):int =
  if p==nil: 0 else: int(generationNative(p.native))

proc windowLive*(p:SelectProvider):bool =
  p!=nil and windowLiveNative(p.native)!=0

when defined(leafProtocolProbes):
  proc probeArmNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_arm",header:Header.}
  proc probeWaitEnteredNative(p:ptr NativeProvider,timeoutMs:int32):int32 {.importc:"leaf_select_probe_wait_entered",header:Header.}
  proc probeReleaseNative(p:ptr NativeProvider) {.importc:"leaf_select_probe_release",header:Header,raises:[].}
  proc probeMeasureNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_measure_value",header:Header,raises:[].}
  proc probeNavigateNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_navigate_child",header:Header,raises:[].}
  proc probeCountsNative(live,allocated,freed,readers:ptr cint,p:ptr NativeProvider) {.importc:"leaf_select_probe_counts",header:Header,raises:[].}

  proc probeArm*(p:SelectProvider) =
    if p==nil: fail("select provider is missing")
    check(probeArmNative(p.native),"Arm select provider read barrier")
  proc probeWaitEntered*(p:SelectProvider,timeoutMs:int):bool =
    p!=nil and probeWaitEnteredNative(p.native,int32(timeoutMs))==1
  proc probeRelease*(p:SelectProvider) =
    if p!=nil: probeReleaseNative(p.native)
  proc probeMeasureValue*(p:SelectProvider):int =
    if p==nil: -1 else: int(probeMeasureNative(p.native))
  proc probeNativePointer*(p:SelectProvider):pointer =
    (if p==nil: nil else: cast[pointer](p.native))
  proc probeMeasureValueRaw*(native:pointer):int =
    ## GC-safe entry for a reader thread: no Nim ref crosses the thread.
    if native==nil: -1 else: int(probeMeasureNative(cast[ptr NativeProvider](native)))
  proc probeNavigateChild*(p:SelectProvider):bool =
    p!=nil and probeNavigateNative(p.native)==1
  proc probeSetValueNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_set_value",header:Header,raises:[].}
  proc probeArmExitNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_arm_exit",header:Header.}
  proc probeWaitExitNative(p:ptr NativeProvider,timeoutMs:int32):int32 {.importc:"leaf_select_probe_wait_exit",header:Header.}
  proc probeReleaseExitNative(p:ptr NativeProvider) {.importc:"leaf_select_probe_release_exit",header:Header,raises:[].}
  proc probeArmExit*(p:SelectProvider) =
    if p==nil: fail("select provider is missing")
    check(probeArmExitNative(p.native),"Arm select provider exit barrier")
  proc probeWaitExit*(p:SelectProvider,timeoutMs:int):bool =
    p!=nil and probeWaitExitNative(p.native,int32(timeoutMs))==1
  proc probeReleaseExit*(p:SelectProvider) =
    if p!=nil: probeReleaseExitNative(p.native)
  proc probeArmPeerNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_arm_peer",header:Header.}
  proc probeWaitPeerNative(p:ptr NativeProvider,timeoutMs:int32):int32 {.importc:"leaf_select_probe_wait_peer",header:Header.}
  proc probeReleasePeerNative(p:ptr NativeProvider) {.importc:"leaf_select_probe_release_peer",header:Header,raises:[].}
  proc probePeerFreedNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_peer_freed",header:Header,raises:[].}
  proc probePublishCountsNative(published,reclaims,mismatch:ptr cint) {.importc:"leaf_select_probe_publish_counts",header:Header,raises:[].}
  proc probePublishCounts*():tuple[published,reclaims,mismatch:int] =
    var published,reclaims,mismatch:cint
    probePublishCountsNative(addr published,addr reclaims,addr mismatch)
    (int(published),int(reclaims),int(mismatch))
  proc probeArmPeer*(p:SelectProvider) =
    if p==nil: fail("select provider is missing")
    check(probeArmPeerNative(p.native),"Arm select provider peer barrier")
  proc probeWaitPeer*(p:SelectProvider,timeoutMs:int):bool =
    p!=nil and probeWaitPeerNative(p.native,int32(timeoutMs))==1
  proc probeReleasePeer*(p:SelectProvider) =
    if p!=nil: probeReleasePeerNative(p.native)
  proc probePeerFreed*(p:SelectProvider):int =
    if p==nil: -1 else: int(probePeerFreedNative(p.native))
  proc probeIdentityNative(p:ptr NativeProvider):int64 {.importc:"leaf_select_probe_identity",header:Header,raises:[].}
  proc probeIdentity*(p:SelectProvider):int64 =
    if p==nil: 0 else: probeIdentityNative(p.native)
  proc probeFreedProvidersNative():int32 {.importc:"leaf_select_probe_freed_providers",header:Header,raises:[].}
  proc probeFreedProviders*():int =
    int(probeFreedProvidersNative())
  proc probeNavigateChildRaw*(native:pointer):int =
    if native==nil: -1 else: int(probeNavigateNative(cast[ptr NativeProvider](native)))
  proc probeArmDrainNative(p:ptr NativeProvider):int32 {.importc:"leaf_select_probe_arm_drain",header:Header.}
  proc probeWaitDrainNative(p:ptr NativeProvider,timeoutMs:int32):int32 {.importc:"leaf_select_probe_wait_drain",header:Header.}
  proc probeReleaseDrainNative(p:ptr NativeProvider) {.importc:"leaf_select_probe_release_drain",header:Header,raises:[].}
  proc probeArmDrain*(p:SelectProvider) =
    if p==nil: fail("select provider is missing")
    check(probeArmDrainNative(p.native),"Arm select provider drain barrier")
  proc probeWaitDrain*(p:SelectProvider,timeoutMs:int):bool =
    p!=nil and probeWaitDrainNative(p.native,int32(timeoutMs))==1
  proc probeReleaseDrain*(p:SelectProvider) =
    if p!=nil: probeReleaseDrainNative(p.native)
  proc probeSetValue*(p:SelectProvider):int =
    if p==nil: -1 else: int(probeSetValueNative(p.native))
  proc probeCounts*(p:SelectProvider):tuple[live,allocated,freed,readers:int] =
    var live,allocated,freed,readers:cint
    probeCountsNative(addr live,addr allocated,addr freed,addr readers,
      (if p==nil: nil else: p.native))
    (int(live),int(allocated),int(freed),int(readers))
