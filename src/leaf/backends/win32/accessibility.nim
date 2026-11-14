## Owned Dynamic Annotation service and receipts. No new HWND, subclass or UIA
## provider; the stock Windows proxy continues to own all native patterns.
import std/[os,strutils,tables]
import ../../[core,backend]
import ../../ui/fields
import ./[api,measure]
const BridgeHeader=(currentSourcePath.parentDir/"accessibility_bridge.h").replace('\\','/')
{.compile:"accessibility_bridge.c".}
{.passL:"-lole32 -loleaut32".}
type
  NativeService {.importc:"LeafAnnotations",header:BridgeHeader,incompleteStruct.}=object
  AnnotationReceipt = ref object
    field:FieldAssociation
    complete:bool
    mask:uint32
  NativeAnnotations* = ref object
    service:ptr NativeService
    owner:DWORD
    receipts:Table[HWND,AnnotationReceipt]
proc nativeNew(output:ptr ptr NativeService):int32 {.importc:"leaf_annotations_new",header:BridgeHeader.}
proc nativeRelease(a:ptr NativeService) {.importc:"leaf_annotations_release",header:BridgeHeader.}
proc nativeClear(a:ptr NativeService,window:pointer,mask:ptr uint32):int32 {.importc:"leaf_annotations_clear",header:BridgeHeader.}
proc nativeSet(a:ptr NativeService,window:pointer,name,help:ptr uint16,mask:ptr uint32):int32 {.importc:"leaf_annotations_set",header:BridgeHeader.}
proc status(hr:int32,operation:string) =
  if hr<0:fail(operation & " failed HRESULT 0x" & toHex(cast[uint32](hr),8))
proc checkOwner(a:NativeAnnotations) =
  if a.owner!=GetCurrentThreadId():fail("Field annotations require their owning UI thread")
proc annotate*(a:var NativeAnnotations,window:HWND,field:FieldAssociation) =
  if a==nil:a=NativeAnnotations(owner:GetCurrentThreadId())
  a.checkOwner()
  if a.service==nil:status(nativeNew(addr a.service),"Create Field annotation service")
  if a.receipts.hasKey(window) and a.receipts[window].complete and
      a.receipts[window].field==field:return
  let name=checkedWide(field.name)
  let help=checkedWide(field.help)
  # Record ownership *before* the first mutating annotation call, so a partial
  # failure is still cleared during rollback/disposal. Never cache it as valid.
  let receipt=a.receipts.mgetOrPut(window,AnnotationReceipt())
  receipt.field=field
  receipt.complete=false
  status(nativeSet(a.service,window,unsafeAddr name[0],unsafeAddr help[0],
    addr receipt.mask),"Annotate Field")
  receipt.complete=true
proc clear*(a:NativeAnnotations,window:HWND) =
  if a==nil:return
  a.checkOwner()
  if window notin a.receipts:return
  status(nativeClear(a.service,window,addr a.receipts[window].mask),"Clear Field annotations")
  a.receipts.del(window)
proc retain*(a:NativeAnnotations,windows:Table[HWND,FieldAssociation]) =
  if a==nil:return
  a.checkOwner()
  var stale:seq[HWND]
  for window in a.receipts.keys:
    if window notin windows:stale.add(window)
  for window in stale:a.clear(window)
proc close*(a:NativeAnnotations) =
  if a==nil:return
  a.checkOwner()
  if a.receipts.len!=0:fail("Field annotation receipts still own native windows")
  if a.service!=nil:nativeRelease(a.service);a.service=nil
proc counts*(a:NativeAnnotations):tuple[services,windows:int] =
  if a==nil:return
  a.checkOwner()
  result=(int(a.service!=nil),a.receipts.len)
