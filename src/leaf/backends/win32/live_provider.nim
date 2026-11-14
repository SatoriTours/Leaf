## Dedicated live semantics for status/alert HWNDs only. No EDIT provider changes.
## Stage during native apply, mark accepted without effects, flush on a safe turn.
##
## Lifecycle contract for callers:
## * every owner call (create/stage/accept/discard/flush/detach/drain/close) runs
##   on the HWND owner thread; provider callbacks may run on other threads and
##   only read the C snapshot;
## * accept is effect-free; flush publishes and notifies, so it belongs to a
##   normal native turn, never to a synchronous SendMessage/COM input call;
## * detach only tombstones and queues the owned reference. Call drainRetired at
##   the next safe turn; setWake gives that turn a bounded trigger instead of
##   waiting for the next user input;
## * a re-entrant drain/close (for example from a provider callback) is refused
##   with E_UNEXPECTED rather than walking the queue twice.
when not defined(windows): {.error:"Native live semantics require Windows".}
import std/[os,strutils]
import ../../core
import ./[api,measure]
const Header=(currentSourcePath.parentDir/"live_provider.h").replace('\\','/')
{.compile:"live_provider.c".}
{.passL:"-lole32 -loleaut32".}
when defined(leafProtocolProbes):
  {.passC:"-DLEAF_LIVE_PROVIDER_PROBES".}
type
  Context {.importc:"LeafLiveContext",header:Header,incompleteStruct.}=object
  Provider {.importc:"LeafLiveProvider",header:Header,incompleteStruct.}=object
  LiveKind* {.pure.}=enum status=1,alert=2
  LiveContext* = ref object
    native:ptr Context
  LiveProvider* = ref object
    native:ptr Provider
proc contextNew(outp:ptr ptr Context):int32 {.importc:"leaf_live_context_new",header:Header.}
proc contextClose(p:ptr ptr Context):int32 {.importc:"leaf_live_context_close",header:Header.}
proc create(c:ptr Context,w:pointer,k:cint,n:ptr uint16,outp:ptr ptr Provider):int32 {.importc:"leaf_live_create",header:Header.}
proc stageNative(p:ptr Provider,k:cint,n:ptr uint16):int32 {.importc:"leaf_live_stage",header:Header.}
proc acceptNative(p:ptr Provider) {.importc:"leaf_live_accept",header:Header,raises:[].}
proc discardNative(p:ptr Provider) {.importc:"leaf_live_discard",header:Header,raises:[].}
proc flushNative(p:ptr Provider,changed:ptr cint):int32 {.importc:"leaf_live_flush",header:Header.}
proc getObjectNative(p:ptr Provider,wp:uint,lp:int):int {.importc:"leaf_live_get_object",header:Header,raises:[].}
proc detachNative(p:ptr ptr Provider):int32 {.importc:"leaf_live_detach",header:Header.}
proc drainNative(c:ptr Context):int32 {.importc:"leaf_live_drain",header:Header.}
proc setWakeNative(c:ptr Context,w:pointer,m:uint32):int32 {.importc:"leaf_live_context_set_wake",header:Header.}
proc countsNative(c:ptr Context,owned,objects:ptr cint) {.importc:"leaf_live_counts",header:Header.}
proc check(hr:int32,operation:string)=
  if hr<0:fail(operation & " HRESULT 0x" & toHex(cast[uint32](hr),8))
proc newLiveContext*():LiveContext=
  result=LiveContext();check(contextNew(addr result.native),"Create live context")
proc newLiveProvider*(c:LiveContext,w:HWND,kind:LiveKind,name:string):LiveProvider=
  if c==nil:fail("live provider requires a context")
  let wide=checkedWide(name)
  result=LiveProvider()
  check(create(c.native,cast[pointer](w),cint(ord(kind)),unsafeAddr wide[0],addr result.native),"Create live provider")
proc stage*(p:LiveProvider,kind:LiveKind,name:string)=
  if p==nil:fail("live provider is missing")
  let wide=checkedWide(name)
  check(stageNative(p.native,cint(ord(kind)),unsafeAddr wide[0]),"Stage live semantics")
proc accept*(p:LiveProvider) {.raises:[].}=
  if p!=nil:acceptNative(p.native)
proc discardStage*(p:LiveProvider) {.raises:[].}=
  if p!=nil:discardNative(p.native)
proc flush*(p:LiveProvider):bool=
  if p==nil:return false
  var changed:cint
  check(flushNative(p.native,addr changed),"Publish live semantics")
  changed!=0
proc objectResult*(p:LiveProvider,wp:WPARAM,lp:LPARAM):LRESULT {.raises:[].}=
  if p!=nil:LRESULT(getObjectNative(p.native,uint(wp),int(lp))) else:0
proc detach*(p:LiveProvider)=
  if p!=nil:check(detachNative(addr p.native),"Detach live provider")
## Bounded wake-up for the owner loop: after a provider is detached the context
## posts one custom message (0x8000..0xBFFF) to `window` so the loop can call
## drainRetired without waiting for the next user input. Pass nil to disable.
proc setWake*(c:LiveContext,w:HWND,message:uint32)=
  if c==nil:fail("live wake requires a context")
  check(setWakeNative(c.native,cast[pointer](w),message),"Configure live wake")
## Call at an ordinary owner turn outside synchronous SendMessage/COM input.
proc drainRetired*(c:LiveContext)=
  if c!=nil:check(drainNative(c.native),"Drain retired live providers")
proc close*(c:LiveContext)=
  if c!=nil:check(contextClose(addr c.native),"Close live context")
proc counts*(c:LiveContext):tuple[owned,objects:int]=
  var owned,objects:cint
  countsNative((if c==nil:nil else:c.native),addr owned,addr objects)
  (int(owned),int(objects))
