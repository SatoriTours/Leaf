#define COBJMACROS
#include <windows.h>
#include <uiautomationcore.h>
#include <uiautomationcoreapi.h>
#include <stdlib.h>
#include <wchar.h>
#include "live_provider.h"

#define ELEMENT_GONE ((HRESULT)0x80040201L)
#define NAME_ID 30005
#define LIVE_ID 30135
#define LIVE_EVENT 20024
/* SDK GUID: IRawElementProviderSimple. No registration or replacement of EDIT. */
static const GUID simpleIID={0xd6dd68d1,0x86fd,0x4332,{0x86,0x66,0x9a,0xbe,0xde,0xa2,0xd2,0x4c}};
static const GUID unknownIID={0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
/* Older MinGW SDKs have the ABI but no UIAutomationCore import library.
   Resolve the required API from System32 only; absence is a hard failure.
   The one loader reference lasts for the process, like a static DLL import:
   releasing it from a provider callback could unload code on the call stack. */
static INIT_ONCE apiOnce=INIT_ONCE_STATIC_INIT;
static HRESULT (WINAPI *apiHost)(HWND,IRawElementProviderSimple **);
static HRESULT (WINAPI *apiDisconnect)(IRawElementProviderSimple *);
static HRESULT (WINAPI *apiEvent)(IRawElementProviderSimple *,EVENTID);
static HRESULT (WINAPI *apiProperty)(IRawElementProviderSimple *,PROPERTYID,VARIANT,VARIANT);
static LRESULT (WINAPI *apiReturn)(HWND,WPARAM,LPARAM,IRawElementProviderSimple *);
static BOOL (WINAPI *apiListening)(void);
static BOOL CALLBACK loadApi(PINIT_ONCE once,PVOID parameter,PVOID *context){
 (void)once;(void)parameter;(void)context;
 HMODULE dll=LoadLibraryExW(L"UIAutomationCore.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
 if(!dll)return FALSE;
 #define RESOLVE(target,name) do { *(FARPROC*)&target=GetProcAddress(dll,name);if(!target){FreeLibrary(dll);SetLastError(ERROR_PROC_NOT_FOUND);return FALSE;} } while(0)
 RESOLVE(apiHost,"UiaHostProviderFromHwnd");RESOLVE(apiDisconnect,"UiaDisconnectProvider");
 RESOLVE(apiEvent,"UiaRaiseAutomationEvent");RESOLVE(apiProperty,"UiaRaiseAutomationPropertyChangedEvent");
 RESOLVE(apiReturn,"UiaReturnRawElementProvider");RESOLVE(apiListening,"UiaClientsAreListening");
 #undef RESOLVE
 return TRUE;
}

typedef struct Snapshot { BSTR name; int kind; struct Snapshot *next; } Snapshot;
struct LeafLiveContext {
 LONG refs,objects; DWORD owner;
 int initialized,closed,owned,draining;
 HWND wake; UINT wakeMessage;
 LeafLiveProvider *retired;
};
struct LeafLiveProvider {
 IRawElementProviderSimple iface; LONG refs; SRWLOCK lock;
 LeafLiveContext *context;
 HWND window; IRawElementProviderSimple *host;
 BSTR name; int kind,published,exposed,flushing,disconnecting;
 LeafLiveProvider *retiredNext;
 /* UI-owner-only state, never consulted by provider callbacks. */
 Snapshot *staged,*ready;
};
#ifdef LEAF_LIVE_PROVIDER_PROBES
/* Test-only seam, compiled only with -DLEAF_LIVE_PROVIDER_PROBES. */
static LeafLiveProbeHooks probeHooks;
static int probeActive;
void leaf_live_probe_hooks(const LeafLiveProbeHooks *hooks){
 if(hooks)probeHooks=*hooks;else ZeroMemory(&probeHooks,sizeof(probeHooks));
 probeActive=hooks!=NULL;
}
int leaf_live_probe_exposed(LeafLiveProvider *p){return p?p->exposed:0;}
#endif
/* Every call that hands the provider to UIA goes through these wrappers so the
   probe seam can fake the boundary without a second code path. */
static HRESULT disconnectCall(LeafLiveProvider *p){
#ifdef LEAF_LIVE_PROVIDER_PROBES
 if(probeActive&&probeHooks.disconnect)return probeHooks.disconnect(&p->iface);
#endif
 return apiDisconnect(&p->iface);
}
static HRESULT eventCall(LeafLiveProvider *p,EVENTID id){
#ifdef LEAF_LIVE_PROVIDER_PROBES
 if(probeActive&&probeHooks.event)return probeHooks.event(&p->iface,id);
#endif
 return apiEvent(&p->iface,id);
}
static HRESULT propertyCall(LeafLiveProvider *p,PROPERTYID id,VARIANT before,VARIANT after){
#ifdef LEAF_LIVE_PROVIDER_PROBES
 if(probeActive&&probeHooks.property)return probeHooks.property(&p->iface,id,before,after);
#endif
 return apiProperty(&p->iface,id,before,after);
}
static BOOL listeningCall(void){
#ifdef LEAF_LIVE_PROVIDER_PROBES
 if(probeActive&&probeHooks.listening)return probeHooks.listening();
#endif
 return apiListening();
}
static LRESULT returnCall(LeafLiveProvider *p,WPARAM wp,LPARAM lp){
#ifdef LEAF_LIVE_PROVIDER_PROBES
 if(probeActive&&probeHooks.returnRaw)return probeHooks.returnRaw(p->window,wp,lp,&p->iface);
#endif
 return apiReturn(p->window,wp,lp,&p->iface);
}
static void contextRelease(LeafLiveContext *c){if(InterlockedDecrement(&c->refs)==0)free(c);}
static HRESULT owner(LeafLiveContext *c){
 if(!c)return E_POINTER;
 if(c->owner!=GetCurrentThreadId())return RPC_E_WRONG_THREAD;
 return c->closed?ELEMENT_GONE:S_OK;
}
static HRESULT writable(LeafLiveProvider *p){
 if(!p)return E_POINTER;HRESULT hr=owner(p->context);
 if(FAILED(hr))return hr;return p->window?S_OK:ELEMENT_GONE;
}
/* Provider callbacks run on other threads: only these two may touch state
   shared with the owner, and both take the lock. */
static int snapshotLive(LeafLiveProvider *p){
 AcquireSRWLockShared(&p->lock);int alive=p->window!=NULL&&p->published;ReleaseSRWLockShared(&p->lock);return alive;
}
static void markExposed(LeafLiveProvider *p){
 AcquireSRWLockExclusive(&p->lock);
 if(p->window&&p->published)p->exposed=1;
 ReleaseSRWLockExclusive(&p->lock);
}
static void freeSnapshots(Snapshot *s){while(s){Snapshot *next=s->next;SysFreeString(s->name);free(s);s=next;}}
static HRESULT nameLength(const uint16_t *s,UINT *length){
 if(!s||!length)return E_POINTER;
 for(UINT n=0;n<=65535;n++){
  uint16_t u=s[n];if(!u){if(n==0)return E_INVALIDARG;*length=n;return S_OK;}
  if(n==65535)return E_INVALIDARG;
  if(u>=0xd800&&u<=0xdbff){
   if(n+1>=65535||s[n+1]<0xdc00||s[n+1]>0xdfff)return E_INVALIDARG;
   n++;
  }else if(u>=0xdc00&&u<=0xdfff)return E_INVALIDARG;
 }
 return E_INVALIDARG;
}
static ULONG STDMETHODCALLTYPE addRef(IRawElementProviderSimple *self){return InterlockedIncrement(&((LeafLiveProvider*)self)->refs);}
static ULONG STDMETHODCALLTYPE release(IRawElementProviderSimple *self){
 LeafLiveProvider *p=(LeafLiveProvider*)self;LONG n=InterlockedDecrement(&p->refs);
 if(!n){
  if(p->host)IRawElementProviderSimple_Release(p->host);
  SysFreeString(p->name);freeSnapshots(p->staged);freeSnapshots(p->ready);
  InterlockedDecrement(&p->context->objects);contextRelease(p->context);free(p);
 }
 return n;
}
static HRESULT STDMETHODCALLTYPE query(IRawElementProviderSimple *self,REFIID iid,void **out){
 if(!out)return E_POINTER;*out=NULL;
 if(IsEqualGUID(iid,&unknownIID)||IsEqualGUID(iid,&simpleIID)){*out=self;addRef(self);return S_OK;}
 return E_NOINTERFACE;
}
static HRESULT STDMETHODCALLTYPE options(IRawElementProviderSimple *self,enum ProviderOptions *out){
 if(!out)return E_POINTER;LeafLiveProvider *p=(LeafLiveProvider*)self;
 AcquireSRWLockShared(&p->lock);int alive=(p->window&&p->published)||p->disconnecting;ReleaseSRWLockShared(&p->lock);
 if(!alive)return ELEMENT_GONE;
 *out=(enum ProviderOptions)(2|32); /* ServerSideProvider | UseComThreading */
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE pattern(IRawElementProviderSimple *self,PATTERNID id,IUnknown **out){
 (void)id;if(!out)return E_POINTER;*out=NULL;LeafLiveProvider *p=(LeafLiveProvider*)self;
 AcquireSRWLockShared(&p->lock);int alive=p->window&&p->published;ReleaseSRWLockShared(&p->lock);
 return alive?S_OK:ELEMENT_GONE;
}
static HRESULT STDMETHODCALLTYPE property(IRawElementProviderSimple *self,PROPERTYID id,VARIANT *out){
 if(!out)return E_POINTER;VariantInit(out);LeafLiveProvider *p=(LeafLiveProvider*)self;
 AcquireSRWLockShared(&p->lock);
 if(!p->window||!p->published){ReleaseSRWLockShared(&p->lock);return ELEMENT_GONE;}
 HRESULT hr=S_OK;
 switch(id){
 case 30003:out->vt=VT_I4;out->lVal=p->kind==1?50017:50026;break; /* StatusBar / Group */
 case LIVE_ID:out->vt=VT_I4;out->lVal=p->kind;break; /* Polite / Assertive */
 case NAME_ID:case 30004:
  out->vt=VT_BSTR;out->bstrVal=SysAllocString(id==NAME_ID?p->name:(p->kind==1?L"status":L"alert"));
  if(!out->bstrVal){out->vt=VT_EMPTY;hr=E_OUTOFMEMORY;}break;
 case 30009:out->vt=VT_BOOL;out->boolVal=VARIANT_FALSE;break; /* not focusable */
 case 30010:case 30016:case 30017:out->vt=VT_BOOL;out->boolVal=VARIANT_TRUE;break;
 default:break; /* VT_EMPTY delegates bounds, HWND and other facts to the host. */
 }
 ReleaseSRWLockShared(&p->lock);return hr;
}
static HRESULT STDMETHODCALLTYPE hostProvider(IRawElementProviderSimple *self,IRawElementProviderSimple **out){
 if(!out)return E_POINTER;*out=NULL;LeafLiveProvider *p=(LeafLiveProvider*)self;
 AcquireSRWLockShared(&p->lock);
 if((!p->window||!p->published)&&!p->disconnecting){ReleaseSRWLockShared(&p->lock);return ELEMENT_GONE;}
 *out=p->host;if(*out)IRawElementProviderSimple_AddRef(*out);
 ReleaseSRWLockShared(&p->lock);return S_OK;
}
static IRawElementProviderSimpleVtbl table={query,addRef,release,options,pattern,property,hostProvider};
int32_t leaf_live_context_new(LeafLiveContext **out){
 if(!out)return E_POINTER;*out=NULL;
 HRESULT hr=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
 if(FAILED(hr)&&hr!=RPC_E_CHANGED_MODE)return hr;
 int initialized=SUCCEEDED(hr);
 if(!InitOnceExecuteOnce(&apiOnce,loadApi,NULL,NULL)){hr=HRESULT_FROM_WIN32(GetLastError());if(initialized)CoUninitialize();return hr;}
 LeafLiveContext *c=calloc(1,sizeof(*c));
 if(!c){if(initialized)CoUninitialize();return E_OUTOFMEMORY;}
 c->refs=1;c->owner=GetCurrentThreadId();c->initialized=initialized;*out=c;return S_OK;
}
int32_t leaf_live_context_set_wake(LeafLiveContext *c,void *window,uint32_t message){
 HRESULT hr=owner(c);if(FAILED(hr))return hr;
 if(window){
  HWND w=(HWND)window;
  if(!IsWindow(w))return E_INVALIDARG;
  if(GetWindowThreadProcessId(w,NULL)!=c->owner)return RPC_E_WRONG_THREAD;
  if(message<0x8000u||message>0xbfffu)return E_INVALIDARG;
 }
 c->wake=window?(HWND)window:NULL;c->wakeMessage=window?(UINT)message:0;
 return S_OK;
}
int32_t leaf_live_context_close(LeafLiveContext **slot){
 if(!slot)return E_POINTER;if(!*slot)return S_OK;LeafLiveContext *c=*slot;
 HRESULT hr=owner(c);if(FAILED(hr))return hr;
 /* Refuse instead of freeing a context whose queue another frame is draining. */
 if(c->draining)return E_UNEXPECTED;
 if(c->owned)return E_UNEXPECTED;
 hr=leaf_live_drain(c);if(FAILED(hr))return hr;
 c->closed=1;*slot=NULL;
 if(c->initialized)CoUninitialize();contextRelease(c);return S_OK;
}
int32_t leaf_live_stage(LeafLiveProvider *p,int kind,const uint16_t *name){
 HRESULT hr=writable(p);if(FAILED(hr))return hr;if(kind!=1&&kind!=2)return E_INVALIDARG;
 UINT length=0;hr=nameLength(name,&length);if(FAILED(hr))return hr;
 Snapshot *accepted=p->ready;
 BSTR current=accepted?accepted->name:p->name;int currentKind=accepted?accepted->kind:p->kind;
 int same=current&&kind==currentKind&&wcscmp(current,(const WCHAR*)name)==0;
 Snapshot *s=NULL;
 if(!same){
  s=calloc(1,sizeof(*s));if(!s)return E_OUTOFMEMORY;
  s->name=SysAllocStringLen((const WCHAR*)name,length);s->kind=kind;
  if(!s->name){free(s);return E_OUTOFMEMORY;}
 }
 /* Compact older accepted snapshots here, never in accept. At most two
    ready snapshots exist; a rejected candidate cannot erase the latest one. */
 if(accepted){freeSnapshots(accepted->next);accepted->next=NULL;}
 freeSnapshots(p->staged);p->staged=s;return S_OK;
}
int32_t leaf_live_create(LeafLiveContext *c,void *window,int kind,const uint16_t *name,LeafLiveProvider **out){
 if(!out)return E_POINTER;*out=NULL;HRESULT hr=owner(c);if(FAILED(hr))return hr;
 if(!window||!IsWindow((HWND)window))return E_INVALIDARG;
 DWORD thread=GetWindowThreadProcessId((HWND)window,NULL);if(thread!=c->owner)return RPC_E_WRONG_THREAD;
 LeafLiveProvider *p=calloc(1,sizeof(*p));if(!p)return E_OUTOFMEMORY;
 p->iface.lpVtbl=&table;p->refs=1;p->context=c;p->window=(HWND)window;InitializeSRWLock(&p->lock);
 InterlockedIncrement(&c->refs);InterlockedIncrement(&c->objects);
 hr=leaf_live_stage(p,kind,name);
 if(SUCCEEDED(hr))hr=apiHost(p->window,&p->host);
 if(FAILED(hr)){release(&p->iface);return hr;}
 c->owned++;*out=p;return S_OK;
}
void leaf_live_accept(LeafLiveProvider *p){
 if(!p||!p->staged)return;
 p->staged->next=p->ready;p->ready=p->staged;p->staged=NULL;
}
void leaf_live_discard(LeafLiveProvider *p){
 if(FAILED(writable(p)))return;
 freeSnapshots(p->staged);p->staged=NULL;
}
int32_t leaf_live_flush(LeafLiveProvider *p,int *changed){
 if(!changed)return E_POINTER;*changed=0;
 HRESULT hr=writable(p);if(FAILED(hr))return hr;
 if(p->flushing)return E_UNEXPECTED;if(!p->ready)return S_OK;
 p->flushing=1;addRef(&p->iface);
 /* The snapshot and the old name are owned by this frame until it returns:
    a re-entrant detach may tombstone the provider, but cannot free them. */
 Snapshot *ready=p->ready;p->ready=NULL;
 AcquireSRWLockExclusive(&p->lock);
 BSTR old=p->name;int oldKind=p->kind;int wasPublished=p->published;
 int different=!wasPublished||oldKind!=ready->kind||!old||wcscmp(old,ready->name)!=0;
 p->name=ready->name;ready->name=NULL;p->kind=ready->kind;p->published=1;
 BSTR current=p->name;ReleaseSRWLockExclusive(&p->lock);
 freeSnapshots(ready);*changed=different;
 if(different&&IsWindowVisible(p->window)&&listeningCall()){
  /* Notification also hands the provider to UIA, so it creates the same
     disconnect obligation as WM_GETOBJECT even without an exposed HWND. */
  markExposed(p);
  VARIANT before,after;VariantInit(&before);VariantInit(&after);
  before.vt=VT_BSTR;before.bstrVal=old;after.vt=VT_BSTR;after.bstrVal=current;
  if(wasPublished&&wcscmp(old,current)!=0&&snapshotLive(p))hr=propertyCall(p,NAME_ID,before,after);
  if(wasPublished&&oldKind!=p->kind&&snapshotLive(p)){
   VARIANT oldValue,newValue;VariantInit(&oldValue);VariantInit(&newValue);
   oldValue.vt=newValue.vt=VT_I4;oldValue.lVal=oldKind;newValue.lVal=p->kind;
   /* Re-check before every notification: a detach inside the previous callback
      tombstones the provider and must stop the rest of this flush. */
   HRESULT propertyHr=propertyCall(p,LIVE_ID,oldValue,newValue);
   if(SUCCEEDED(hr))hr=propertyHr;
   if(snapshotLive(p)){
    oldValue.lVal=oldKind==1?50017:50026;newValue.lVal=p->kind==1?50017:50026;
    propertyHr=propertyCall(p,30003,oldValue,newValue);if(SUCCEEDED(hr))hr=propertyHr;
   }
   if(snapshotLive(p)){
    oldValue.vt=newValue.vt=VT_BSTR;
    oldValue.bstrVal=SysAllocString(oldKind==1?L"status":L"alert");
    newValue.bstrVal=SysAllocString(p->kind==1?L"status":L"alert");
    propertyHr=oldValue.bstrVal&&newValue.bstrVal?propertyCall(p,30004,oldValue,newValue):E_OUTOFMEMORY;
    if(SUCCEEDED(hr))hr=propertyHr;
   }
   VariantClear(&oldValue);VariantClear(&newValue);
  }
  if(snapshotLive(p)){
   HRESULT eventHr=eventCall(p,LIVE_EVENT);
   if(SUCCEEDED(hr))hr=eventHr;
  }
 }
 SysFreeString(old);p->flushing=0;release(&p->iface);return hr;
}
intptr_t leaf_live_get_object(LeafLiveProvider *p,uintptr_t wp,intptr_t lp){
 if((LONG)lp!=-25||FAILED(writable(p))||!p->published)return 0;
 markExposed(p);return returnCall(p,(WPARAM)wp,(LPARAM)lp);
}
int32_t leaf_live_detach(LeafLiveProvider **slot){
 if(!slot)return E_POINTER;if(!*slot)return S_OK;LeafLiveProvider *p=*slot;
 HRESULT hr=writable(p);if(FAILED(hr))return hr;
 AcquireSRWLockExclusive(&p->lock);p->window=NULL;p->published=0;ReleaseSRWLockExclusive(&p->lock);
 *slot=NULL;p->context->owned--;
 LeafLiveContext *c=p->context;
 /* Posting is not outbound COM; one message per pending batch keeps the owner
    loop waking even when the retirement came from a synchronous message. */
 int first=c->retired==NULL;
 p->retiredNext=c->retired;c->retired=p;
 if(first&&c->wake)PostMessageW(c->wake,c->wakeMessage,0,0);
 return S_OK;
}
int32_t leaf_live_drain(LeafLiveContext *c){
 HRESULT hr=owner(c);if(FAILED(hr))return hr;
 /* UIA may re-enter the owner thread from UiaDisconnectProvider. A nested
    drain would walk the same queue, so refuse it instead of corrupting it. */
 if(c->draining)return E_UNEXPECTED;
 if(InSendMessageEx(NULL)&(ISMEX_SEND|ISMEX_NOTIFY|ISMEX_CALLBACK))return RPC_E_CANTCALLOUT_ININPUTSYNCCALL;
 c->draining=1;
 while(c->retired){
  LeafLiveProvider *p=c->retired;
  /* Unlink before the outbound call: a re-entrant detach must enqueue behind
     this frame, not be overwritten when the call returns. */
  c->retired=p->retiredNext;p->retiredNext=NULL;
  /* UIA needs stable provider identity to disconnect. Semantic queries remain
     tombstoned; WM_GETOBJECT must NOT republish this retiring provider. */
  AcquireSRWLockExclusive(&p->lock);p->disconnecting=1;ReleaseSRWLockExclusive(&p->lock);
  hr=p->exposed?disconnectCall(p):S_OK;
  AcquireSRWLockExclusive(&p->lock);p->disconnecting=0;ReleaseSRWLockExclusive(&p->lock);
  if(FAILED(hr)){
   /* Keep the owned retirement receipt for diagnosis without losing nodes that
      were enqueued by the re-entrant call. */
   p->retiredNext=c->retired;c->retired=p;c->draining=0;return hr;
  }
  release(&p->iface);
 }
 c->draining=0;
 return S_OK;
}
void leaf_live_counts(LeafLiveContext *c,int *owned,int *objects){
 if(owned)*owned=c?c->owned:0;
 if(objects)*objects=c?InterlockedCompareExchange(&c->objects,0,0):0;
}
