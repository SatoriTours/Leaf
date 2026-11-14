#define COBJMACROS
#include <windows.h>
#include <oleauto.h>
#include <stdlib.h>
#include <wchar.h>
#include <string.h>
#include "select_uia.h"
#include "select_provider.h"

#ifdef LEAF_SELECT_PROVIDER_PROBES
#include <stdio.h>
/* Probe-only instrumentation: counts real snapshot allocations/frees and can
   pause a real reader after it has acquired its snapshot, so a controlled
   concurrency test can observe the owner publishing while the reader is inside.
   It never changes the read algorithm and never frees anything itself. */
static volatile LONG64 probeAllocated, probeFreed, probePublished, probeReclaims;
static volatile LONG probeMismatch;
static volatile LONG64 probeIdentitySeq;
static volatile LONG probeFreedProviders;
/* Bounded registry of freed provider objects, so a probe can detect that a raw
   peer pointer was used after its release without dereferencing it. */
#define PROBE_FREED_MAX 256
static LeafProvider *probeFreedList[PROBE_FREED_MAX];
static volatile LONG probeFreedCount;
static void probeRecordFreed(LeafProvider *p){
 InterlockedIncrement(&probeFreedProviders);
 LONG slot=InterlockedIncrement(&probeFreedCount)-1;
 if(p)probeFreedList[slot%PROBE_FREED_MAX]=p;
}
static int probeIsFreed(LeafProvider *p){
 LONG count=InterlockedCompareExchange(&probeFreedCount,0,0);
 LONG limit=count<PROBE_FREED_MAX?count:PROBE_FREED_MAX;
 for(LONG i=0;i<limit;i++)if(probeFreedList[i]==p)return 1;
 return 0;
}
#define PROBE_MISMATCH(n) InterlockedExchange(&probeMismatch,(LONG)(n))
#define PROBE_COUNT_ALLOC() InterlockedIncrement64(&probeAllocated)
#define PROBE_COUNT_FREE() InterlockedIncrement64(&probeFreed)
static void traceTo(const char *message){
 /* Probe seam only: opt in with LEAF_SELECT_PROVIDER_TRACE=1 so an ordinary
    run writes nothing. Compiled only with -d:leafProtocolProbes. */
 char enabled[8];
 if(GetEnvironmentVariableA("LEAF_SELECT_PROVIDER_TRACE",enabled,sizeof(enabled))==0)
   return;
 if(enabled[0]=='0'||enabled[0]==0)return;
 char path[MAX_PATH],temp[MAX_PATH];
 DWORD n=GetTempPathA(MAX_PATH,temp);
 if(n==0||n>=MAX_PATH)return;
 wsprintfA(path,"%sleaf-select-provider.log",temp);
 FILE *file=fopen(path,"a");
 if(!file)return;
 fprintf(file,"pid=%lu %s\n",(unsigned long)GetCurrentProcessId(),message);
 fclose(file);
}
#define TRACE(x) traceTo(x)
#else
#define TRACE(x) do{}while(0)
#define PROBE_MISMATCH(n) do{}while(0)
#define PROBE_COUNT_ALLOC() do{}while(0)
#define PROBE_COUNT_FREE() do{}while(0)
#endif

#define ELEMENT_GONE ((HRESULT)0x80040201L)     /* UIA_E_ELEMENTNOTAVAILABLE */
#define ELEMENT_NOT_ENABLED ((HRESULT)0x80040200L)
#define NOT_SUPPORTED_HR ((HRESULT)0x80040204L)
#define INVALID_OPERATION ((HRESULT)0x80131509L)

/* IIDs extracted from the shipped .NET Framework 4.8 provider assembly; see
   select_uia.h and the artifact note. Declared locally because the toolchain
   header only carries IRawElementProviderSimple/IAccessibleEx. */
static const GUID iidSimple={0xd6dd68d1,0x86fd,0x4332,{0x86,0x66,0x9a,0xbe,0xde,0xa2,0xd2,0x4c}};
static const GUID iidFragment={0xf7063da8,0x8359,0x439c,{0x92,0x97,0xbb,0xc5,0x29,0x9a,0x7d,0x87}};
static const GUID iidFragmentRoot={0x620ce2a5,0xab8f,0x40a9,{0x86,0xcb,0xde,0x3c,0x75,0x59,0x9b,0x58}};
static const GUID iidExpand={0xd847d3a5,0xcab0,0x4a98,{0x8c,0x32,0xec,0xb4,0x5c,0x59,0xad,0x24}};
static const GUID iidValue={0xc7935180,0x6fb3,0x4201,{0xb1,0x74,0x7d,0xf7,0x3a,0xdb,0xf6,0x4a}};
static const GUID iidSelection={0xfb8b03af,0x3bdf,0x48d4,{0xbd,0x36,0x1a,0x65,0x79,0x3b,0xe1,0x68}};
static const GUID iidSelectionItem={0x2acad808,0xb2d4,0x452d,{0xa4,0x07,0x91,0xff,0x1a,0xd1,0x67,0xb2}};
static const GUID iidUnknown={0,0,0,{0xc0,0,0,0,0,0,0,0x46}};

static INIT_ONCE apiOnce=INIT_ONCE_STATIC_INIT;
static HRESULT (WINAPI *apiHost)(HWND,IRawElementProviderSimple **);
static HRESULT (WINAPI *apiDisconnect)(IRawElementProviderSimple *);
static HRESULT (WINAPI *apiEvent)(IRawElementProviderSimple *,EVENTID);
static HRESULT (WINAPI *apiProperty)(IRawElementProviderSimple *,PROPERTYID,VARIANT,VARIANT);
static HRESULT (WINAPI *apiStructure)(IRawElementProviderSimple *,int,int *,int);
static LRESULT (WINAPI *apiReturn)(HWND,WPARAM,LPARAM,IRawElementProviderSimple *);
static BOOL (WINAPI *apiListening)(void);
static BOOL CALLBACK loadApi(PINIT_ONCE once,PVOID parameter,PVOID *context){
 (void)once;(void)parameter;(void)context;
 HMODULE dll=LoadLibraryExW(L"UIAutomationCore.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
 if(!dll)return FALSE;
 #define RESOLVE(target,name) do { *(FARPROC*)&target=GetProcAddress(dll,name);if(!target){FreeLibrary(dll);SetLastError(ERROR_PROC_NOT_FOUND);return FALSE;} } while(0)
 RESOLVE(apiHost,"UiaHostProviderFromHwnd");
 RESOLVE(apiDisconnect,"UiaDisconnectProvider");
 RESOLVE(apiEvent,"UiaRaiseAutomationEvent");
 RESOLVE(apiProperty,"UiaRaiseAutomationPropertyChangedEvent");
 RESOLVE(apiStructure,"UiaRaiseStructureChangedEvent");
 RESOLVE(apiReturn,"UiaReturnRawElementProvider");
 RESOLVE(apiListening,"UiaClientsAreListening");
 #undef RESOLVE
 return TRUE;
}

typedef struct LeafItem { BSTR label; int disabled; int selected; } LeafItem;
typedef struct LeafSnapshot {
  int open,enabled,focused,visible,selectedIndex,count,firstRow,rows,rowHeight;
  BSTR name,value;
  LeafItem *items;
  struct LeafSnapshot *next;
} LeafSnapshot;

typedef struct LeafItemProvider LeafItemProvider;
typedef struct LeafProvider LeafProvider;

struct LeafProvider {
  IRawElementProviderSimple simple;
  LeafUiaFragment fragment;
  LeafUiaFragmentRoot root;
  LeafUiaExpand expand;
  LeafUiaValue value;
  LeafUiaSelection selection;
  LONG refs;
  SRWLOCK lock;                 /* unused; kept for structural stability */
  LeafSelectContext *context;
  HWND window;
  int kind;                 /* 1 trigger, 2 popup */
  int id;
  IRawElementProviderSimple *host;
  LeafSnapshot *published,*ready,*staged;
  LeafProvider *popup;      /* trigger -> popup, weak */
  LeafProvider *trigger;    /* popup -> trigger, weak */
  LONG generation;
  volatile LONG windowLive,publishedFlag,exposed,flushing,disconnecting;
  volatile LONG returning;      /* UiaReturnRawElementProvider is not re-entrant */
  volatile LONG readers;        /* UIA threads currently reading the snapshot */
  LeafSnapshot *retiredSnapshots;
#ifdef LEAF_SELECT_PROVIDER_PROBES
  HANDLE probeEntered,probeRelease;
  HANDLE probeExitEntered,probeExitRelease;
  HANDLE probeDrainEntered,probeDrainRelease;
  volatile LONG probeArmed;
  volatile LONG probeExitArmed;
  volatile LONG probeDrainArmed;
  volatile LONG probePeerArmed;
  HANDLE probePeerEntered,probePeerRelease;
  volatile LONG probePeerFreed;
  volatile LONG64 probeIdentity;
#endif
  LeafProvider *retiredNext;
  LONG refsHeldByLink;
};

struct LeafItemProvider {
  IRawElementProviderSimple simple;
  LeafUiaFragment fragment;
  LeafUiaSelectionItem item;
  LONG refs;
  LeafProvider *parent;
  int index;
  int id;
};

struct LeafSelectContext {
  LONG refs,objects;
  DWORD owner;
  int initialized,closed,owned,draining;
  HWND wake;
  UINT wakeMessage;
  SRWLOCK requestLock;
  SRWLOCK linkLock;         /* protects trigger<->popup link and peer pinning */
  LONG requestKind,requestIndex,requestGeneration;
  HWND requestWindow;
  LeafProvider *retired;
};

static void contextRelease(LeafSelectContext *c){if(InterlockedDecrement(&c->refs)==0)free(c);}
static HRESULT owner(LeafSelectContext *c){
 if(!c)return E_POINTER;
 if(c->owner!=GetCurrentThreadId())return RPC_E_WRONG_THREAD;
 return c->closed?ELEMENT_GONE:S_OK;
}
static void freeSnapshot(LeafSnapshot *s){
 if(!s)return;
 PROBE_COUNT_FREE();
 SysFreeString(s->name);SysFreeString(s->value);
 for(int i=0;i<s->count;i++)SysFreeString(s->items[i].label);
 free(s->items);free(s);
}
static void freeSnapshots(LeafSnapshot *s){while(s){LeafSnapshot *next=s->next;freeSnapshot(s);s=next;}}
static int sameSnapshot(LeafSnapshot *a,const uint16_t *name,const uint16_t *value,
                        const LeafSelectItem *items,int count,int open,int enabled,
                        int selectedIndex,int focused,int visible,int firstRow,int rows,
                        int rowHeight){
 if(!a)return 0;
 if(a->open!=open){
#ifdef LEAF_SELECT_PROVIDER_PROBES
   PROBE_MISMATCH(1);
#endif
   return 0;
 }
 if(a->enabled!=enabled){PROBE_MISMATCH(2);return 0;}
 if(a->selectedIndex!=selectedIndex){PROBE_MISMATCH(3);return 0;}
 if(a->focused!=focused){PROBE_MISMATCH(4);return 0;}
 if(a->visible!=visible){PROBE_MISMATCH(5);return 0;}
 if(a->firstRow!=firstRow){PROBE_MISMATCH(6);return 0;}
 if(a->rows!=rows){PROBE_MISMATCH(7);return 0;}
 if(a->rowHeight!=rowHeight){PROBE_MISMATCH(8);return 0;}
 if(a->count!=count){PROBE_MISMATCH(9);return 0;}
 if(!a->name||!name||wcscmp(a->name,(const WCHAR*)name)!=0){PROBE_MISMATCH(10);return 0;}
 {
   const WCHAR *stored=a->value?a->value:L"";
   const WCHAR *wanted=value?(const WCHAR*)value:L"";
   if(wcscmp(stored,wanted)!=0){PROBE_MISMATCH(11);return 0;}
 }
 for(int i=0;i<count;i++){
   if((a->items[i].disabled!=0)!=(items[i].disabled!=0)){PROBE_MISMATCH(12);return 0;}
   if(!a->items[i].label||!items[i].label){PROBE_MISMATCH(13);return 0;}
   if((int)wcslen(a->items[i].label)!=(int)items[i].length){PROBE_MISMATCH(14);return 0;}
   if(wcsncmp(a->items[i].label,(const WCHAR*)items[i].label,(size_t)items[i].length)!=0){PROBE_MISMATCH(15);return 0;}
 }
 return 1;
}
static LeafSnapshot *copySnapshot(const uint16_t *name,const uint16_t *value,
                                  const LeafSelectItem *items,int count,int selectedIndex,
                                  int open,int enabled,int focused,int visible,int firstRow,
                                  int rows,int rowHeight){
 LeafSnapshot *s=(LeafSnapshot*)calloc(1,sizeof(*s));
 if(!s)return NULL;
 PROBE_COUNT_ALLOC();
 s->open=open;s->enabled=enabled;s->selectedIndex=selectedIndex;s->focused=focused;
 s->visible=visible;s->firstRow=firstRow;s->rows=rows;s->rowHeight=rowHeight;s->count=count;
 s->name=SysAllocString(name?(const WCHAR*)name:L"");
 s->value=SysAllocString(value?(const WCHAR*)value:L"");
 if(!s->name||!s->value){freeSnapshot(s);return NULL;}
 if(count>0){
   s->items=(LeafItem*)calloc((size_t)count,sizeof(LeafItem));
   if(!s->items){freeSnapshot(s);return NULL;}
   for(int i=0;i<count;i++){
     s->items[i].disabled=items[i].disabled?1:0;
     s->items[i].selected=(i==selectedIndex)?1:0;
     s->items[i].label=SysAllocStringLen((const WCHAR*)items[i].label,(UINT)items[i].length);
     if(!s->items[i].label){freeSnapshot(s);return NULL;}
   }
 }
 return s;
}
static HRESULT writable(LeafProvider *p){
 if(!p)return E_POINTER;
 HRESULT hr=owner(p->context);
 if(FAILED(hr))return hr;
 return p->windowLive?S_OK:ELEMENT_GONE;
}
/* Read path: no locks. The published snapshot pointer is swapped atomically by
   the owner thread and retired snapshots are freed only when no reader is
   inside, so a UIA thread can never block the owner thread (and vice versa). */
static LeafSnapshot *snapshotOf(LeafProvider *p){
 return (LeafSnapshot*)InterlockedCompareExchangePointer((PVOID volatile*)&p->published,NULL,NULL);
}
/* Read protocol: a reader counts itself IN before it loads the pointer, then uses
   that one snapshot and counts out. The owner only retires snapshots it has
   already replaced, so a pointer a reader holds is never the current one and can
   only be reclaimed after readers drops to zero. */
static LeafSnapshot *readGuardEnter(LeafProvider *p){
 InterlockedIncrement(&p->readers);
 LeafSnapshot *snapshot=snapshotOf(p);
#ifdef LEAF_SELECT_PROVIDER_PROBES
 if(InterlockedCompareExchange(&p->probeArmed,0,0)){
   if(p->probeEntered)SetEvent(p->probeEntered);
   if(p->probeRelease)WaitForSingleObject(p->probeRelease,30000);
 }
#endif
 return snapshot;
}
static void reclaimRetired(LeafProvider *p);
static void readGuardExit(LeafProvider *p){
 if(InterlockedDecrement(&p->readers)==0){
#ifdef LEAF_SELECT_PROVIDER_PROBES
   if(InterlockedCompareExchange(&p->probeExitArmed,0,0)){
     if(p->probeExitEntered)SetEvent(p->probeExitEntered);
     if(p->probeExitRelease)WaitForSingleObject(p->probeExitRelease,30000);
   }
#endif
   /* Readers never free: the owner is the only reclaimer. The last reader only
      nudges the owner through the ordinary wake so the chain can be collected
      in a normal turn even without another publish. */
   LeafSelectContext *context=p->context;
   if(context&&!context->closed&&context->wake)
     PostMessageW(context->wake,context->wakeMessage,0,0);
 }
}
/* A retired snapshot is no longer the current one; it is only freed after every
   reader that may hold it left its read guard. The list is a lock-free stack
   (CAS push) drained by exactly one thread at a time (atomic exchange). */
static void retireSnapshot(LeafProvider *p,LeafSnapshot *s){
 if(!s)return;
 s->next=NULL;
 for(;;){
   LeafSnapshot *head=(LeafSnapshot*)InterlockedCompareExchangePointer(
     (PVOID volatile*)&p->retiredSnapshots,NULL,NULL);
   s->next=head;
   if(InterlockedCompareExchangePointer((PVOID volatile*)&p->retiredSnapshots,
       s,head)==head)break;
 }
}
/* Owner-only reclamation. The owner is the only thread that publishes and the
   only one that pushes to the retired stack, so between the readers==0 check and
   the exchange below nothing can retire a new snapshot (no COM, event or message
   pumping happens in between). A reader that enters after the check loads the
   CURRENT published snapshot, which is never part of the retired stack. */
static void reclaimRetired(LeafProvider *p){
 if(InterlockedCompareExchange(&p->readers,0,0)!=0)return;
#ifdef LEAF_SELECT_PROVIDER_PROBES
 if(InterlockedCompareExchange(&p->probeDrainArmed,0,0)){
   if(p->probeDrainEntered)SetEvent(p->probeDrainEntered);
   if(p->probeDrainRelease)WaitForSingleObject(p->probeDrainRelease,30000);
 }
#endif
 LeafSnapshot *list=(LeafSnapshot*)InterlockedExchangePointer(
   (PVOID volatile*)&p->retiredSnapshots,NULL);
 if(list){
#ifdef LEAF_SELECT_PROVIDER_PROBES
   InterlockedIncrement64(&probeReclaims);
#endif
   freeSnapshots(list);
 }
}
static int snapshotLive(LeafProvider *p){
 return InterlockedCompareExchange(&p->windowLive,0,0)!=0 &&
   InterlockedCompareExchange(&p->publishedFlag,0,0)!=0;
}
static void setVariantInt(VARIANT *out,int value){VariantInit(out);out->vt=VT_I4;out->lVal=value;}
static void setVariantBool(VARIANT *out,int value){VariantInit(out);out->vt=VT_BOOL;out->boolVal=value?VARIANT_TRUE:VARIANT_FALSE;}
static HRESULT setVariantBstr(VARIANT *out,BSTR value){
 VariantInit(out);
 out->vt=VT_BSTR;out->bstrVal=value;
 return value?S_OK:E_OUTOFMEMORY;
}
static HRESULT array4(SAFEARRAY **out,double a,double b,double c,double d){
 SAFEARRAY *array=SafeArrayCreateVector(VT_R8,0,4);
 if(!array)return E_OUTOFMEMORY;
 double values[4]={a,b,c,d};
 for(LONG i=0;i<4;i++)SafeArrayPutElement(array,&i,&values[i]);
 *out=array;return S_OK;
}
static HRESULT runtimeIdArray(SAFEARRAY **out,int kind,int id,int index){
 int values[4];
 int count=3;
 values[0]=(int)GetCurrentProcessId();
 values[1]=kind;
 values[2]=id;
 if(index>=0){values[3]=index;count=4;}
 SAFEARRAY *array=SafeArrayCreateVector(VT_I4,0,(ULONG)count);
 if(!array)return E_OUTOFMEMORY;
 for(LONG i=0;i<count;i++)SafeArrayPutElement(array,&i,&values[i]);
 *out=array;return S_OK;
}
static HRESULT providerArray(SAFEARRAY **out,IRawElementProviderSimple **items,int count){
 SAFEARRAY *array=SafeArrayCreateVector(VT_UNKNOWN,0,(ULONG)(count>0?count:1));
 if(!array)return E_OUTOFMEMORY;
 LONG index=0;
 if(count==0){IUnknown *none=NULL;SafeArrayPutElement(array,&index,&none);}
 for(int i=0;i<count;i++){
   LONG slot=index;
   SafeArrayPutElement(array,&slot,&items[i]);
   index++;
 }
 *out=array;return S_OK;
}
static void rectOf(HWND window,double *values){
 RECT frame;ZeroMemory(&frame,sizeof(frame));
 if(window)GetWindowRect(window,&frame);
 values[0]=frame.left;values[1]=frame.top;
 values[2]=frame.right-frame.left;values[3]=frame.bottom-frame.top;
}
static void noteRequest(LeafProvider *p,int kind,int index){
 LeafSelectContext *c=p->context;
 if(!c||c->closed)return;
 AcquireSRWLockExclusive(&c->requestLock);
 if(c->requestKind==LEAF_SELECT_REQUEST_NONE){
   c->requestKind=kind;
   c->requestIndex=index;
   c->requestGeneration=(LONG)InterlockedCompareExchange(&p->generation,0,0);
   c->requestWindow=p->window;
 }
 ReleaseSRWLockExclusive(&c->requestLock);
 if(c->wake)PostMessageW(c->wake,c->wakeMessage,0,0);
}

/* ---------------- item providers (List items of the popup) ---------------- */

static ULONG STDMETHODCALLTYPE itemAddRef(IRawElementProviderSimple *self);
static ULONG STDMETHODCALLTYPE itemRelease(IRawElementProviderSimple *self);
static HRESULT STDMETHODCALLTYPE itemQuery(IRawElementProviderSimple *self,REFIID iid,void **out);
static HRESULT STDMETHODCALLTYPE itemOptions(IRawElementProviderSimple *self,enum ProviderOptions *out);
static HRESULT STDMETHODCALLTYPE itemPattern(IRawElementProviderSimple *self,PATTERNID id,IUnknown **out);
static HRESULT STDMETHODCALLTYPE itemProperty(IRawElementProviderSimple *self,PROPERTYID id,VARIANT *out);
static HRESULT STDMETHODCALLTYPE itemHost(IRawElementProviderSimple *self,IRawElementProviderSimple **out);
static HRESULT STDMETHODCALLTYPE itemNavigate(LeafUiaFragment *self,enum LeafNavigateDirection direction,LeafUiaFragment **out);
static HRESULT STDMETHODCALLTYPE itemRuntimeId(LeafUiaFragment *self,SAFEARRAY **out);
static HRESULT STDMETHODCALLTYPE itemBounds(LeafUiaFragment *self,struct UiaRect *out);
static HRESULT STDMETHODCALLTYPE itemEmbedded(LeafUiaFragment *self,SAFEARRAY **out);
static HRESULT STDMETHODCALLTYPE itemSetFocus(LeafUiaFragment *self);
static HRESULT STDMETHODCALLTYPE itemFragmentRoot(LeafUiaFragment *self,LeafUiaFragmentRoot **out);
static HRESULT STDMETHODCALLTYPE itemSelect(LeafUiaSelectionItem *self);
static HRESULT STDMETHODCALLTYPE itemAddToSelection(LeafUiaSelectionItem *self);
static HRESULT STDMETHODCALLTYPE itemRemoveFromSelection(LeafUiaSelectionItem *self);
static HRESULT STDMETHODCALLTYPE itemSelected(LeafUiaSelectionItem *self,BOOL *out);
static HRESULT STDMETHODCALLTYPE itemContainer(LeafUiaSelectionItem *self,LeafUiaFragment **out);

/* COM identity: a vtable entry receives the interface pointer it was called on,
   which is not the object base for any embedded interface. Each interface
   therefore gets its own QueryInterface/AddRef/Release thunks that recover the
   real object first. */
static HRESULT STDMETHODCALLTYPE itemFragQuery(LeafUiaFragment *self,REFIID iid,void **out){
 return itemQuery(&((LeafItemProvider*)((char*)self-offsetof(LeafItemProvider,fragment)))->simple,iid,out);
}
static ULONG STDMETHODCALLTYPE itemFragAddRef(LeafUiaFragment *self){
 return itemAddRef(&((LeafItemProvider*)((char*)self-offsetof(LeafItemProvider,fragment)))->simple);
}
static ULONG STDMETHODCALLTYPE itemFragRelease(LeafUiaFragment *self){
 return itemRelease(&((LeafItemProvider*)((char*)self-offsetof(LeafItemProvider,fragment)))->simple);
}
static HRESULT STDMETHODCALLTYPE itemItemQuery(LeafUiaSelectionItem *self,REFIID iid,void **out){
 return itemQuery(&((LeafItemProvider*)((char*)self-offsetof(LeafItemProvider,item)))->simple,iid,out);
}
static ULONG STDMETHODCALLTYPE itemItemAddRef(LeafUiaSelectionItem *self){
 return itemAddRef(&((LeafItemProvider*)((char*)self-offsetof(LeafItemProvider,item)))->simple);
}
static ULONG STDMETHODCALLTYPE itemItemRelease(LeafUiaSelectionItem *self){
 return itemRelease(&((LeafItemProvider*)((char*)self-offsetof(LeafItemProvider,item)))->simple);
}
static const IRawElementProviderSimpleVtbl itemSimpleVtbl={itemQuery,itemAddRef,itemRelease,
  itemOptions,itemPattern,itemProperty,itemHost};
static const LeafUiaFragmentVtbl itemFragmentVtbl={itemFragQuery,itemFragAddRef,itemFragRelease,
  itemNavigate,itemRuntimeId,itemBounds,itemEmbedded,itemSetFocus,itemFragmentRoot};
static const LeafUiaSelectionItemVtbl itemSelectionVtbl={itemItemQuery,itemItemAddRef,itemItemRelease,
  itemSelect,itemAddToSelection,itemRemoveFromSelection,itemSelected,itemContainer};

#define ITEM_OF(self) ((LeafItemProvider*)(void*)(self))
#define ITEM_FROM_FRAGMENT(f) ((LeafItemProvider*)(void*)((char*)(f)-offsetof(LeafItemProvider,fragment)))
#define ITEM_FROM_ITEM(i) ((LeafItemProvider*)(void*)((char*)(i)-offsetof(LeafItemProvider,item)))

static LeafItemProvider *newItem(LeafProvider *parent,int index){
 LeafItemProvider *item=(LeafItemProvider*)calloc(1,sizeof(*item));
 if(!item)return NULL;
 item->simple.lpVtbl=&itemSimpleVtbl;
 item->fragment.lpVtbl=&itemFragmentVtbl;
 item->item.lpVtbl=&itemSelectionVtbl;
 item->refs=1;item->parent=parent;item->index=index;item->id=(int)(INT_PTR)item;
 InterlockedIncrement(&parent->refs);
 InterlockedIncrement(&parent->context->objects);
 return item;
}
static ULONG STDMETHODCALLTYPE itemAddRef(IRawElementProviderSimple *self){
 return InterlockedIncrement(&ITEM_OF(self)->refs);
}
static ULONG STDMETHODCALLTYPE itemRelease(IRawElementProviderSimple *self){
 LeafItemProvider *item=ITEM_OF(self);
 LONG n=InterlockedDecrement(&item->refs);
 if(!n){
   LeafProvider *parent=item->parent;
   InterlockedDecrement(&parent->context->objects);
   free(item);
   InterlockedDecrement(&parent->refs);
 }
 return n;
}
static HRESULT STDMETHODCALLTYPE itemQuery(IRawElementProviderSimple *self,REFIID iid,void **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafItemProvider *item=ITEM_OF(self);
 if(IsEqualGUID(iid,&iidUnknown)||IsEqualGUID(iid,&iidSimple)){*out=&item->simple;}
 else if(IsEqualGUID(iid,&iidFragment)){*out=&item->fragment;}
 else if(IsEqualGUID(iid,&iidSelectionItem)){*out=&item->item;}
 else return E_NOINTERFACE;
 itemAddRef(self);
 return S_OK;
}
/* The published snapshot is replaced only under the exclusive lock, so reading
   it under the shared lock is safe from any COM thread. */
static HRESULT STDMETHODCALLTYPE itemOptions(IRawElementProviderSimple *self,enum ProviderOptions *out){
 (void)self;
 if(!out)return E_POINTER;
 *out=(enum ProviderOptions)(2|32);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemPattern(IRawElementProviderSimple *self,PATTERNID id,IUnknown **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafItemProvider *item=ITEM_OF(self);
 LeafProvider *parent=item->parent;
 if(!snapshotLive(parent))return ELEMENT_GONE;
 if(id==LEAF_UIA_PATTERN_SELECTIONITEM){
   *out=(IUnknown*)&item->item;
   itemAddRef(self);
 }
 return S_OK;
}
static HRESULT itemRead(LeafItemProvider *item,LeafSnapshot *s,LeafItem **row,HRESULT failure){
 if(!s)return ELEMENT_GONE;
 if(item->index<0||item->index>=s->count)return failure;
 *row=&s->items[item->index];
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemProperty(IRawElementProviderSimple *self,PROPERTYID id,VARIANT *out){
 if(!out)return E_POINTER;
 VariantInit(out);
 LeafItemProvider *item=ITEM_OF(self);
 LeafProvider *parent=item->parent;
 LeafSnapshot *snapshot=readGuardEnter(parent);
 LeafItem *row=NULL;
 HRESULT hr=itemRead(item,snapshot,&row,ELEMENT_GONE);
 if(FAILED(hr)){readGuardExit(parent);return hr;}
 switch(id){
 case LEAF_UIA_P_CONTROLTYPE:setVariantInt(out,LEAF_UIA_CT_LISTITEM);break;
 case LEAF_UIA_P_NAME:hr=setVariantBstr(out,SysAllocString(row->label));break;
 case LEAF_UIA_P_ENABLED:setVariantBool(out,!row->disabled&&snapshot->enabled);break;
 case LEAF_UIA_P_SELECTED:setVariantBool(out,row->selected);break;
 case LEAF_UIA_P_FOCUSABLE:case LEAF_UIA_P_HASFOCUS:setVariantBool(out,0);break;
 case LEAF_UIA_P_ISCONTROL:case LEAF_UIA_P_ISCONTENT:setVariantBool(out,1);break;
 case LEAF_UIA_P_SELECTIONITEM_AVAILABLE:setVariantBool(out,1);break;
 case LEAF_UIA_P_OFFSCREEN:
   setVariantBool(out,!snapshot->visible||item->index<snapshot->firstRow||
     item->index>=snapshot->firstRow+snapshot->rows);
   break;
 case LEAF_UIA_P_BOUNDINGRECT:{
   double values[4];rectOf(parent->window,values);
   int ordinal=item->index-snapshot->firstRow;
   if(snapshot->rows<=0||ordinal<0||ordinal>=snapshot->rows){values[0]=0;values[1]=0;values[2]=0;values[3]=0;}
   else{
     values[1]+=snapshot->rowHeight*ordinal;
     values[3]=snapshot->rowHeight;
   }
   hr=array4(&out->parray,values[0],values[1],values[2],values[3]);
   if(SUCCEEDED(hr))out->vt=VT_ARRAY|VT_R8;
   break;}
 default:break;
 }
 readGuardExit(parent);
 return hr;
}
static HRESULT STDMETHODCALLTYPE itemHost(IRawElementProviderSimple *self,IRawElementProviderSimple **out){
 (void)self;
 if(out)*out=NULL;
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemNavigate(LeafUiaFragment *self,enum LeafNavigateDirection direction,LeafUiaFragment **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafItemProvider *item=ITEM_FROM_FRAGMENT(self);
 LeafProvider *parent=item->parent;
 LeafSnapshot *snaphot=readGuardEnter(parent);
 if(!snaphot){readGuardExit(parent);return ELEMENT_GONE;}
 int count=snaphot->count;
 readGuardExit(parent);
 switch(direction){
 case LeafNavigateParent:
   *out=&parent->fragment;InterlockedIncrement(&parent->refs);break;
 case LeafNavigateNextSibling:
   if(item->index+1<count){LeafItemProvider *next=newItem(parent,item->index+1);if(next)*out=&next->fragment;}
   break;
 case LeafNavigatePreviousSibling:
   if(item->index>0){LeafItemProvider *prev=newItem(parent,item->index-1);if(prev)*out=&prev->fragment;}
   break;
 default:break;
 }
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemRuntimeId(LeafUiaFragment *self,SAFEARRAY **out){
 if(!out)return E_POINTER;
 LeafItemProvider *item=ITEM_FROM_FRAGMENT(self);
 return runtimeIdArray(out,3,item->parent->id,item->index);
}
static HRESULT STDMETHODCALLTYPE itemBounds(LeafUiaFragment *self,struct UiaRect *out){
 if(!out)return E_POINTER;
 LeafItemProvider *item=ITEM_FROM_FRAGMENT(self);
 LeafProvider *parent=item->parent;
 LeafSnapshot *snapshot=readGuardEnter(parent);
 LeafItem *row=NULL;
 HRESULT hr=itemRead(item,snapshot,&row,ELEMENT_GONE);
 if(SUCCEEDED(hr)){
   double values[4];rectOf(parent->window,values);
   int ordinal=item->index-snapshot->firstRow;
   if(snapshot->rows<=0||ordinal<0||ordinal>=snapshot->rows){values[0]=0;values[1]=0;values[2]=0;values[3]=0;}
   else{values[1]+=snapshot->rowHeight*ordinal;values[3]=snapshot->rowHeight;}
   out->left=values[0];out->top=values[1];out->width=values[2];out->height=values[3];
 }
 readGuardExit(parent);
 return hr;
}
static HRESULT STDMETHODCALLTYPE itemEmbedded(LeafUiaFragment *self,SAFEARRAY **out){
 (void)self;
 if(out)*out=NULL;
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemSetFocus(LeafUiaFragment *self){
 LeafItemProvider *item=ITEM_FROM_FRAGMENT(self);
 LeafProvider *parent=item->parent;
 LeafSnapshot *snaphot=readGuardEnter(parent);
 int enabled=snaphot!=NULL;
 int disabled=1;
 if(enabled&&item->index>=0&&item->index<snaphot->count)
   disabled=snaphot->items[item->index].disabled;
 readGuardExit(parent);
 if(!enabled)return ELEMENT_GONE;
 if(disabled)return ELEMENT_NOT_ENABLED;
 noteRequest(parent,LEAF_SELECT_REQUEST_FOCUS,item->index);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemFragmentRoot(LeafUiaFragment *self,LeafUiaFragmentRoot **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafItemProvider *item=ITEM_FROM_FRAGMENT(self);
 LeafProvider *parent=item->parent;
 if(!parent->windowLive)return ELEMENT_GONE;
 *out=&parent->root;
 InterlockedIncrement(&parent->refs);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemSelect(LeafUiaSelectionItem *self){
 LeafItemProvider *item=ITEM_FROM_ITEM(self);
 LeafProvider *parent=item->parent;
 LeafSnapshot *snaphot=readGuardEnter(parent);
 int alive=snaphot!=NULL;
 int disabled=1;
 int visible=0;
 if(alive&&item->index>=0&&item->index<snaphot->count){
   disabled=snaphot->items[item->index].disabled;
   visible=snaphot->visible&&item->index>=snaphot->firstRow&&
     item->index<snaphot->firstRow+snaphot->rows;
 }
 readGuardExit(parent);
 if(!alive)return ELEMENT_GONE;
 if(disabled)return ELEMENT_NOT_ENABLED;
 if(!visible)return ELEMENT_NOT_ENABLED;
 noteRequest(parent,LEAF_SELECT_REQUEST_SELECT,item->index);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE itemAddToSelection(LeafUiaSelectionItem *self){
 (void)self;
 return INVALID_OPERATION;   /* single select only */
}
static HRESULT STDMETHODCALLTYPE itemRemoveFromSelection(LeafUiaSelectionItem *self){
 (void)self;
 return INVALID_OPERATION;   /* the accepted value is caller-owned */
}
static HRESULT STDMETHODCALLTYPE itemSelected(LeafUiaSelectionItem *self,BOOL *out){
 if(!out)return E_POINTER;
 LeafItemProvider *item=ITEM_FROM_ITEM(self);
 LeafProvider *parent=item->parent;
 LeafSnapshot *snapshot=readGuardEnter(parent);
 LeafItem *row=NULL;
 HRESULT hr=itemRead(item,snapshot,&row,ELEMENT_GONE);
 if(SUCCEEDED(hr))*out=row->selected?VARIANT_TRUE:VARIANT_FALSE;
 readGuardExit(parent);
 return hr;
}
static HRESULT STDMETHODCALLTYPE itemContainer(LeafUiaSelectionItem *self,LeafUiaFragment **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafItemProvider *item=ITEM_FROM_ITEM(self);
 LeafProvider *parent=item->parent;
 if(!parent->windowLive)return ELEMENT_GONE;
 *out=&parent->fragment;
 InterlockedIncrement(&parent->refs);
 return S_OK;
}

/* ------------------------- main (window) providers ------------------------- */

#define PROV_OF(self) ((LeafProvider*)(void*)(self))
#define PROV_FROM_FRAGMENT(f) ((LeafProvider*)(void*)((char*)(f)-offsetof(LeafProvider,fragment)))
#define PROV_FROM_ROOT(r) ((LeafProvider*)(void*)((char*)(r)-offsetof(LeafProvider,root)))
#define PROV_FROM_EXPAND(e) ((LeafProvider*)(void*)((char*)(e)-offsetof(LeafProvider,expand)))
#define PROV_FROM_VALUE(v) ((LeafProvider*)(void*)((char*)(v)-offsetof(LeafProvider,value)))
#define PROV_FROM_SELECTION(s) ((LeafProvider*)(void*)((char*)(s)-offsetof(LeafProvider,selection)))

static LeafProvider *pinPeer(LeafProvider *p,int wantPopup);
static void unlinkPeer(LeafProvider *p);
static ULONG STDMETHODCALLTYPE provAddRef(IRawElementProviderSimple *self);
static ULONG STDMETHODCALLTYPE provRelease(IRawElementProviderSimple *self);
static HRESULT STDMETHODCALLTYPE provQuery(IRawElementProviderSimple *self,REFIID iid,void **out);
static HRESULT STDMETHODCALLTYPE provOptions(IRawElementProviderSimple *self,enum ProviderOptions *out);
static HRESULT STDMETHODCALLTYPE provPattern(IRawElementProviderSimple *self,PATTERNID id,IUnknown **out);
static HRESULT STDMETHODCALLTYPE provProperty(IRawElementProviderSimple *self,PROPERTYID id,VARIANT *out);
static HRESULT STDMETHODCALLTYPE provHost(IRawElementProviderSimple *self,IRawElementProviderSimple **out);
static HRESULT STDMETHODCALLTYPE provNavigate(LeafUiaFragment *self,enum LeafNavigateDirection direction,LeafUiaFragment **out);
static HRESULT STDMETHODCALLTYPE provRuntimeId(LeafUiaFragment *self,SAFEARRAY **out);
static HRESULT STDMETHODCALLTYPE provBounds(LeafUiaFragment *self,struct UiaRect *out);
static HRESULT STDMETHODCALLTYPE provEmbedded(LeafUiaFragment *self,SAFEARRAY **out);
static HRESULT STDMETHODCALLTYPE provSetFocus(LeafUiaFragment *self);
static HRESULT STDMETHODCALLTYPE provFragmentRoot(LeafUiaFragment *self,LeafUiaFragmentRoot **out);
static HRESULT STDMETHODCALLTYPE provFromPoint(LeafUiaFragmentRoot *self,double x,double y,LeafUiaFragment **out);
static HRESULT STDMETHODCALLTYPE provGetFocus(LeafUiaFragmentRoot *self,LeafUiaFragment **out);
static HRESULT STDMETHODCALLTYPE provExpand(LeafUiaExpand *self);
static HRESULT STDMETHODCALLTYPE provCollapse(LeafUiaExpand *self);
static HRESULT STDMETHODCALLTYPE provExpandState(LeafUiaExpand *self,int *out);
static HRESULT STDMETHODCALLTYPE provSetValue(LeafUiaValue *self,LPCWSTR value);
static HRESULT STDMETHODCALLTYPE provGetValue(LeafUiaValue *self,BSTR *out);
static HRESULT STDMETHODCALLTYPE provValueReadOnly(LeafUiaValue *self,BOOL *out);
static HRESULT STDMETHODCALLTYPE provGetSelection(LeafUiaSelection *self,SAFEARRAY **out);
static HRESULT STDMETHODCALLTYPE provSelectionMultiple(LeafUiaSelection *self,BOOL *out);
static HRESULT STDMETHODCALLTYPE provSelectionRequired(LeafUiaSelection *self,BOOL *out);

#define BASE_FRAG(f) ((LeafProvider*)((char*)(f)-offsetof(LeafProvider,fragment)))
#define BASE_ROOT(r) ((LeafProvider*)((char*)(r)-offsetof(LeafProvider,root)))
#define BASE_EXPAND(e) ((LeafProvider*)((char*)(e)-offsetof(LeafProvider,expand)))
#define BASE_VALUE(v) ((LeafProvider*)((char*)(v)-offsetof(LeafProvider,value)))
#define BASE_SELECT(s) ((LeafProvider*)((char*)(s)-offsetof(LeafProvider,selection)))
static HRESULT STDMETHODCALLTYPE fragQuery(LeafUiaFragment *self,REFIID iid,void **out){return provQuery(&BASE_FRAG(self)->simple,iid,out);}
static ULONG STDMETHODCALLTYPE fragAddRef(LeafUiaFragment *self){return provAddRef(&BASE_FRAG(self)->simple);}
static ULONG STDMETHODCALLTYPE fragRelease(LeafUiaFragment *self){return provRelease(&BASE_FRAG(self)->simple);}
static HRESULT STDMETHODCALLTYPE rootQuery(LeafUiaFragmentRoot *self,REFIID iid,void **out){return provQuery(&BASE_ROOT(self)->simple,iid,out);}
static ULONG STDMETHODCALLTYPE rootAddRef(LeafUiaFragmentRoot *self){return provAddRef(&BASE_ROOT(self)->simple);}
static ULONG STDMETHODCALLTYPE rootRelease(LeafUiaFragmentRoot *self){return provRelease(&BASE_ROOT(self)->simple);}
static HRESULT STDMETHODCALLTYPE expandQuery(LeafUiaExpand *self,REFIID iid,void **out){return provQuery(&BASE_EXPAND(self)->simple,iid,out);}
static ULONG STDMETHODCALLTYPE expandAddRef(LeafUiaExpand *self){return provAddRef(&BASE_EXPAND(self)->simple);}
static ULONG STDMETHODCALLTYPE expandRelease(LeafUiaExpand *self){return provRelease(&BASE_EXPAND(self)->simple);}
static HRESULT STDMETHODCALLTYPE valueQuery(LeafUiaValue *self,REFIID iid,void **out){return provQuery(&BASE_VALUE(self)->simple,iid,out);}
static ULONG STDMETHODCALLTYPE valueAddRef(LeafUiaValue *self){return provAddRef(&BASE_VALUE(self)->simple);}
static ULONG STDMETHODCALLTYPE valueRelease(LeafUiaValue *self){return provRelease(&BASE_VALUE(self)->simple);}
static HRESULT STDMETHODCALLTYPE selectionQuery(LeafUiaSelection *self,REFIID iid,void **out){return provQuery(&BASE_SELECT(self)->simple,iid,out);}
static ULONG STDMETHODCALLTYPE selectionAddRef(LeafUiaSelection *self){return provAddRef(&BASE_SELECT(self)->simple);}
static ULONG STDMETHODCALLTYPE selectionRelease(LeafUiaSelection *self){return provRelease(&BASE_SELECT(self)->simple);}
static const IRawElementProviderSimpleVtbl provSimpleVtbl={provQuery,provAddRef,provRelease,
  provOptions,provPattern,provProperty,provHost};
static const LeafUiaFragmentVtbl provFragmentVtbl={fragQuery,fragAddRef,fragRelease,
  provNavigate,provRuntimeId,provBounds,provEmbedded,provSetFocus,provFragmentRoot};
static const LeafUiaFragmentRootVtbl provRootVtbl={rootQuery,rootAddRef,rootRelease,
  provFromPoint,provGetFocus};
static const LeafUiaExpandVtbl provExpandVtbl={expandQuery,expandAddRef,expandRelease,
  provExpand,provCollapse,provExpandState};
static const LeafUiaValueVtbl provValueVtbl={valueQuery,valueAddRef,valueRelease,
  provSetValue,provGetValue,provValueReadOnly};
static const LeafUiaSelectionVtbl provSelectionVtbl={selectionQuery,selectionAddRef,selectionRelease,
  provGetSelection,provSelectionMultiple,provSelectionRequired};

static ULONG STDMETHODCALLTYPE provAddRef(IRawElementProviderSimple *self){
 return InterlockedIncrement(&PROV_OF(self)->refs);
}
static ULONG STDMETHODCALLTYPE provRelease(IRawElementProviderSimple *self){
 LeafProvider *p=PROV_OF(self);
 LONG n=InterlockedDecrement(&p->refs);
 if(!n){
  unlinkPeer(p);
  if(p->host)IRawElementProviderSimple_Release(p->host);
#ifdef LEAF_SELECT_PROVIDER_PROBES
  probeRecordFreed(p);
#endif
  /* COM contract: Release runs only after every client call returned, so no
     reader is inside. Retire the current snapshot, drain the whole chain and
     free the owner-only lists so nothing accumulates. */
  {
    LeafSnapshot *current=(LeafSnapshot*)InterlockedExchangePointer(
      (PVOID volatile*)&p->published,NULL);
    retireSnapshot(p,current);
    LeafSnapshot *list=(LeafSnapshot*)InterlockedExchangePointer(
      (PVOID volatile*)&p->retiredSnapshots,NULL);
    freeSnapshots(list);
  }
  freeSnapshots(p->ready);freeSnapshots(p->staged);
  InterlockedDecrement(&p->context->objects);
  contextRelease(p->context);
  free(p);
 }
 return n;
}
static HRESULT STDMETHODCALLTYPE provQuery(IRawElementProviderSimple *self,REFIID iid,void **out){
 TRACE("query");
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_OF(self);
 if(IsEqualGUID(iid,&iidUnknown)||IsEqualGUID(iid,&iidSimple)){*out=&p->simple;}
 else if(IsEqualGUID(iid,&iidFragment)){*out=&p->fragment;}
 else if(IsEqualGUID(iid,&iidFragmentRoot)){*out=&p->root;}
 else if(p->kind==1&&IsEqualGUID(iid,&iidExpand)){*out=&p->expand;}
 else if(p->kind==1&&IsEqualGUID(iid,&iidValue)){*out=&p->value;}
 else if(p->kind==2&&IsEqualGUID(iid,&iidSelection)){*out=&p->selection;}
 else return E_NOINTERFACE;
 provAddRef(self);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provOptions(IRawElementProviderSimple *self,enum ProviderOptions *out){
 TRACE("options");
 (void)self;
 if(!out)return E_POINTER;
 *out=(enum ProviderOptions)(2|32);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provPattern(IRawElementProviderSimple *self,PATTERNID id,IUnknown **out){
 TRACE("pattern");
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_OF(self);
 if(!snapshotLive(p))return ELEMENT_GONE;
 if(p->kind==1&&id==LEAF_UIA_PATTERN_EXPAND){*out=(IUnknown*)&p->expand;provAddRef(self);}
 else if(p->kind==1&&id==LEAF_UIA_PATTERN_VALUE){*out=(IUnknown*)&p->value;provAddRef(self);}
 else if(p->kind==2&&id==LEAF_UIA_PATTERN_SELECTION){*out=(IUnknown*)&p->selection;provAddRef(self);}
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provProperty(IRawElementProviderSimple *self,PROPERTYID id,VARIANT *out){
 TRACE("prop-enter");
 if(!out)return E_POINTER;
 VariantInit(out);
 LeafProvider *p=PROV_OF(self);
 LeafSnapshot *s=readGuardEnter(p);
 if(!s){readGuardExit(p);return ELEMENT_GONE;}
 HRESULT hr=S_OK;
 switch(id){
 case LEAF_UIA_P_CONTROLTYPE:setVariantInt(out,p->kind==1?LEAF_UIA_CT_COMBOBOX:LEAF_UIA_CT_LIST);break;
 case LEAF_UIA_P_NAME:hr=setVariantBstr(out,SysAllocString(s->name?s->name:L""));break;
 case LEAF_UIA_P_VALUE:
   if(p->kind==1)hr=setVariantBstr(out,SysAllocString(s->value?s->value:L""));
   break;
 case LEAF_UIA_P_VALUE_READONLY:if(p->kind==1)setVariantBool(out,1);break;
 case LEAF_UIA_P_EXPANDSTATE:if(p->kind==1)setVariantInt(out,s->open?1:0);break;
 case LEAF_UIA_P_ENABLED:setVariantBool(out,s->enabled);break;
 case LEAF_UIA_P_FOCUSABLE:setVariantBool(out,1);break;
 case LEAF_UIA_P_HASFOCUS:setVariantBool(out,GetFocus()==p->window);break;
 case LEAF_UIA_P_ISCONTROL:case LEAF_UIA_P_ISCONTENT:setVariantBool(out,1);break;
 case LEAF_UIA_P_OFFSCREEN:
   setVariantBool(out,!(p->kind==2?s->visible:IsWindowVisible(p->window)!=0));break;
 case LEAF_UIA_P_EXPAND_AVAILABLE:setVariantBool(out,p->kind==1);break;
 case LEAF_UIA_P_VALUE_AVAILABLE:setVariantBool(out,p->kind==1);break;
 case LEAF_UIA_P_SELECTION_AVAILABLE:setVariantBool(out,p->kind==2);break;
 case LEAF_UIA_P_SELECTIONITEM_AVAILABLE:setVariantBool(out,0);break;
 case LEAF_UIA_P_SELECTION_MULTIPLE:if(p->kind==2)setVariantBool(out,0);break;
 case LEAF_UIA_P_SELECTION_REQUIRED:if(p->kind==2)setVariantBool(out,0);break;
 case LEAF_UIA_P_BOUNDINGRECT:{
   double values[4];rectOf(p->window,values);
   hr=array4(&out->parray,values[0],values[1],values[2],values[3]);
   if(SUCCEEDED(hr))out->vt=VT_ARRAY|VT_R8;
   break;}
 default:break;
 }
 readGuardExit(p);
 TRACE("prop-done");
 return hr;
}
static HRESULT STDMETHODCALLTYPE provHost(IRawElementProviderSimple *self,IRawElementProviderSimple **out){
 TRACE("host");
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_OF(self);
 if(!snapshotLive(p))return ELEMENT_GONE;
 if(p->host){IRawElementProviderSimple_AddRef(p->host);*out=p->host;}
 return S_OK;
}
/* Peer relationship: the trigger<->popup link is a weak pair protected by the
   context link lock. A caller pins the peer (reads it and takes a strong
   reference) inside the same critical section that unlink uses, so a peer that
   is being unlinked either was pinned first (and stays alive) or is already gone
   (legal empty relation). No lock is held while judging liveness, reading a
   snapshot, calling COM or returning an interface. */
static LeafProvider *pinPeer(LeafProvider *p,int wantPopup){
 if(!p||!p->context)return NULL;
 LeafSelectContext *c=p->context;
 LeafProvider *peer=NULL;
 AcquireSRWLockExclusive(&c->linkLock);
 peer=wantPopup?p->popup:p->trigger;
 if(peer)InterlockedIncrement(&peer->refs);
 ReleaseSRWLockExclusive(&c->linkLock);
#ifdef LEAF_SELECT_PROVIDER_PROBES
 if(peer&&InterlockedCompareExchange(&p->probePeerArmed,0,0)){
   if(p->probePeerEntered)SetEvent(p->probePeerEntered);
   if(p->probePeerRelease)WaitForSingleObject(p->probePeerRelease,30000);
   if(probeIsFreed(peer))InterlockedExchange(&p->probePeerFreed,1);
 }
#endif
 return peer;
}
static void unlinkPeer(LeafProvider *p){
 if(!p||!p->context)return;
 LeafSelectContext *c=p->context;
 AcquireSRWLockExclusive(&c->linkLock);
 if(p->kind==1){
   LeafProvider *peer=p->popup;
   if(peer)peer->trigger=NULL;
   p->popup=NULL;
 } else {
   LeafProvider *peer=p->trigger;
   if(peer)peer->popup=NULL;
   p->trigger=NULL;
 }
 ReleaseSRWLockExclusive(&c->linkLock);
}
static int popupVisible(LeafProvider *trigger){
 LeafProvider *popup=pinPeer(trigger,1);
 if(!popup)return 0;
 int visible=0;
 if(InterlockedCompareExchange(&popup->windowLive,0,0)!=0){
   LeafSnapshot *snapshot=readGuardEnter(popup);
   visible=snapshot!=NULL&&snapshot->visible!=0;
   readGuardExit(popup);
 }
 provRelease(&popup->simple);
 return visible;
}
static HRESULT STDMETHODCALLTYPE provNavigate(LeafUiaFragment *self,enum LeafNavigateDirection direction,LeafUiaFragment **out){
 TRACE("navigate");
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_FROM_FRAGMENT(self);
 if(!snapshotLive(p))return ELEMENT_GONE;
 if(p->kind==1){
   if(direction==LeafNavigateFirstChild||direction==LeafNavigateLastChild){
     /* One navigation pins the peer exactly once. */
     LeafProvider *popup=pinPeer(p,1);
     if(popup){
       int live=InterlockedCompareExchange(&popup->windowLive,0,0)!=0;
       int visible=0;
       if(live){
         LeafSnapshot *snapshot=readGuardEnter(popup);
         visible=snapshot!=NULL&&snapshot->visible!=0;
         readGuardExit(popup);
       }
       if(live&&visible){
         *out=&popup->fragment;   /* the pin becomes the caller's reference */
       } else {
         provRelease(&popup->simple);
       }
     }
   }
   return S_OK;
 }
 /* popup */
 LeafSnapshot *snaphot=readGuardEnter(p);
 int count=snaphot?snaphot->count:0;
 readGuardExit(p);
 if(direction==LeafNavigateParent){
   LeafProvider *trigger=pinPeer(p,0);
   if(trigger){
     if(InterlockedCompareExchange(&trigger->windowLive,0,0)!=0){
       *out=&trigger->fragment;   /* the pin becomes the caller's reference */
     } else {
       provRelease(&trigger->simple);
     }
   }
   return S_OK;
 }
 if(direction==LeafNavigateFirstChild&&count>0){LeafItemProvider *item=newItem(p,0);if(item)*out=&item->fragment;}
 else if(direction==LeafNavigateLastChild&&count>0){LeafItemProvider *item=newItem(p,count-1);if(item)*out=&item->fragment;}
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provRuntimeId(LeafUiaFragment *self,SAFEARRAY **out){
 TRACE("runtimeid");
 if(!out)return E_POINTER;
 LeafProvider *p=PROV_FROM_FRAGMENT(self);
 return runtimeIdArray(out,p->kind,p->id,-1);
}
static HRESULT STDMETHODCALLTYPE provBounds(LeafUiaFragment *self,struct UiaRect *out){
 TRACE("bounds");
 if(!out)return E_POINTER;
 LeafProvider *p=PROV_FROM_FRAGMENT(self);
 double values[4];rectOf(p->window,values);
 out->left=values[0];out->top=values[1];out->width=values[2];out->height=values[3];
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provEmbedded(LeafUiaFragment *self,SAFEARRAY **out){
 (void)self;
 if(out)*out=NULL;
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provSetFocus(LeafUiaFragment *self){
 LeafProvider *p=PROV_FROM_FRAGMENT(self);
 if(!snapshotLive(p))return ELEMENT_GONE;
 noteRequest(p,LEAF_SELECT_REQUEST_FOCUS,p->kind==1?-1:-2);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provFragmentRoot(LeafUiaFragment *self,LeafUiaFragmentRoot **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_FROM_FRAGMENT(self);
 if(!p->windowLive)return ELEMENT_GONE;
 *out=&p->root;InterlockedIncrement(&p->refs);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provFromPoint(LeafUiaFragmentRoot *self,double x,double y,LeafUiaFragment **out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_FROM_ROOT(self);
 LeafSnapshot *s=readGuardEnter(p);
 if(!s||p->kind!=2){readGuardExit(p);return p->windowLive?S_OK:ELEMENT_GONE;}
 RECT frame;GetWindowRect(p->window,&frame);
 int ordinal=(int)((y-frame.top)/ (s->rowHeight>0?s->rowHeight:1));
 int index=s->firstRow+ordinal;
 int inside=ordinal>=0&&ordinal<s->rows&&x>=frame.left&&x<frame.right&&y>=frame.top&&y<frame.bottom;
 readGuardExit(p);
 if(inside&&index>=0){LeafItemProvider *item=newItem(p,index);if(item)*out=&item->fragment;}
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provGetFocus(LeafUiaFragmentRoot *self,LeafUiaFragment **out){
 (void)self;
 if(out)*out=NULL;
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provExpand(LeafUiaExpand *self){
 LeafProvider *p=PROV_FROM_EXPAND(self);
 if(!snapshotLive(p))return ELEMENT_GONE;
 LeafSnapshot *snaphot=readGuardEnter(p);
 int enabled=snaphot!=NULL&&snaphot->enabled;
 readGuardExit(p);
 if(!enabled)return ELEMENT_NOT_ENABLED;
 noteRequest(p,LEAF_SELECT_REQUEST_EXPAND,0);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provCollapse(LeafUiaExpand *self){
 LeafProvider *p=PROV_FROM_EXPAND(self);
 if(!snapshotLive(p))return ELEMENT_GONE;
 noteRequest(p,LEAF_SELECT_REQUEST_COLLAPSE,0);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provExpandState(LeafUiaExpand *self,int *out){
 if(!out)return E_POINTER;
 LeafProvider *p=PROV_FROM_EXPAND(self);
 LeafSnapshot *snaphot=readGuardEnter(p);
 if(!snaphot){readGuardExit(p);return ELEMENT_GONE;}
 *out=snaphot->open?1:0;
 readGuardExit(p);
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provSetValue(LeafUiaValue *self,LPCWSTR value){
 (void)value;
 (void)self;
 /* The accepted value is caller-owned and only changes through the app turn;
      a read-only provider must not pretend to support SetValue. */
 return NOT_SUPPORTED_HR;
}
static HRESULT STDMETHODCALLTYPE provGetValue(LeafUiaValue *self,BSTR *out){
 if(!out)return E_POINTER;
 *out=NULL;
 LeafProvider *p=PROV_FROM_VALUE(self);
 LeafSnapshot *snaphot=readGuardEnter(p);
 if(!snaphot){readGuardExit(p);return ELEMENT_GONE;}
 *out=SysAllocString(snaphot->value?snaphot->value:L"");
 HRESULT hr=*out?S_OK:E_OUTOFMEMORY;
 readGuardExit(p);
 return hr;
}
static HRESULT STDMETHODCALLTYPE provValueReadOnly(LeafUiaValue *self,BOOL *out){
 if(!out)return E_POINTER;
 (void)self;
 *out=VARIANT_TRUE;
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provGetSelection(LeafUiaSelection *self,SAFEARRAY **out){
 if(!out)return E_POINTER;
 LeafProvider *p=PROV_FROM_SELECTION(self);
 LeafSnapshot *snaphot=readGuardEnter(p);
 if(!snaphot){readGuardExit(p);return ELEMENT_GONE;}
 int selected=snaphot->selectedIndex;
 readGuardExit(p);
 if(selected<0)return providerArray(out,(IRawElementProviderSimple**)NULL,0);
 LeafItemProvider *item=newItem(p,selected);
 if(!item)return E_OUTOFMEMORY;
 IRawElementProviderSimple *elements[1];
 elements[0]=&item->simple;
 HRESULT hr=providerArray(out,elements,1);
 itemRelease(&item->simple);   /* the array holds its own reference */
 return hr;
}
static HRESULT STDMETHODCALLTYPE provSelectionMultiple(LeafUiaSelection *self,BOOL *out){
 (void)self;
 if(!out)return E_POINTER;
 *out=VARIANT_FALSE;
 return S_OK;
}
static HRESULT STDMETHODCALLTYPE provSelectionRequired(LeafUiaSelection *self,BOOL *out){
 (void)self;
 if(!out)return E_POINTER;
 *out=VARIANT_FALSE;
 return S_OK;
}

/* ------------------------------ publishing -------------------------------- */

static int listening(void){ return apiListening && apiListening()!=0; }
/* UIA only accepts notifications for a provider it has been handed at least
   once (WM_GETOBJECT); raising earlier dereferences an unknown connection. */
static int canRaise(LeafProvider *p){ return p->exposed && listening(); }
static void raiseProperty(LeafProvider *p,PROPERTYID id,int oldInt,int newInt){
 if(!canRaise(p))return;
 VARIANT before,after;VariantInit(&before);VariantInit(&after);
 before.vt=after.vt=VT_I4;before.lVal=oldInt;after.lVal=newInt;
 apiProperty(&p->simple,id,before,after);
}
static void raisePropertyBstr(LeafProvider *p,PROPERTYID id,const WCHAR *oldText,const WCHAR *newText){
 if(!canRaise(p))return;
 VARIANT before,after;VariantInit(&before);VariantInit(&after);
 before.vt=after.vt=VT_BSTR;
 before.bstrVal=SysAllocString(oldText?oldText:L"");
 after.bstrVal=SysAllocString(newText?newText:L"");
 if(before.bstrVal&&after.bstrVal)apiProperty(&p->simple,id,before,after);
 VariantClear(&before);VariantClear(&after);
}
static void raiseStructure(LeafProvider *p,int change){
#ifdef LEAF_SELECT_PROVIDER_PROBES
 {
  char message[160];
  wsprintfA(message,"structure kind=%d change=%d exposed=%ld listening=%d",
    p->kind,change,(long)InterlockedCompareExchange(&p->exposed,0,0),listening());
  traceTo(message);
 }
#endif
 if(!canRaise(p))return;
 int id[3];id[0]=(int)GetCurrentProcessId();id[1]=p->kind;id[2]=p->id;
 apiStructure(&p->simple,change,id,3);
}
static int sameItems(LeafSnapshot *a,LeafSnapshot *b){
 if(!a||!b)return 0;
 if(a->count!=b->count)return 0;
 for(int i=0;i<a->count;i++){
   if(a->items[i].disabled!=b->items[i].disabled)return 0;
   if(!a->items[i].label||!b->items[i].label)return 0;
   if(wcscmp(a->items[i].label,b->items[i].label)!=0)return 0;
 }
 return 1;
}
int32_t leaf_select_publish(LeafProvider *p,int32_t *changed){
 TRACE("publish-enter");
 if(!changed)return E_POINTER;
 *changed=0;
 HRESULT hr=writable(p);
 if(FAILED(hr))return hr;
 if(InterlockedCompareExchange(&p->flushing,1,0)!=0)return E_UNEXPECTED;
 if(!p->ready){InterlockedExchange(&p->flushing,0);return S_OK;}
 provAddRef(&p->simple);
 LeafSnapshot *ready=p->ready;
 p->ready=NULL;
 if(ready){LeafSnapshot *extra=ready->next;ready->next=NULL;if(extra)retireSnapshot(p,extra);}
 LeafSnapshot *previous=snapshotOf(p);
 InterlockedExchangePointer((PVOID volatile*)&p->published,ready);
 InterlockedExchange(&p->publishedFlag,1);
 InterlockedIncrement(&p->generation);
#ifdef LEAF_SELECT_PROVIDER_PROBES
 InterlockedIncrement64(&probePublished);
#endif
 TRACE("publish-swapped");
 int different=previous==NULL;
 if(previous){
   TRACE("evt-compare");
   if(previous->open!=ready->open){different=1;TRACE("evt-expand");raiseProperty(p,LEAF_UIA_P_EXPANDSTATE,previous->open,ready->open);TRACE("evt-expand-done");}
   if(!previous->name||!ready->name||wcscmp(previous->name,ready->name)!=0){
     different=1;
     raisePropertyBstr(p,LEAF_UIA_P_NAME,previous->name,ready->name);
   }
   if(p->kind==1&&(!previous->value||!ready->value||wcscmp(previous->value,ready->value)!=0)){
     different=1;
     raisePropertyBstr(p,LEAF_UIA_P_VALUE,previous->value,ready->value);
   }
   if(p->kind==1&&previous->visible!=ready->visible){
     different=1;
     TRACE("evt-structure-trigger");
     raiseStructure(p,ready->visible?LeafStructureChildAdded:LeafStructureChildRemoved);
     TRACE("evt-structure-trigger-done");
   }
   if(p->kind==2&&!sameItems(previous,ready)){
     different=1;
     raiseStructure(p,LeafStructureChildrenInvalidated);
   }
   if(p->kind==2&&previous->selectedIndex!=ready->selectedIndex){
     different=1;
     if(canRaise(p))apiEvent(&p->simple,LEAF_UIA_EVENT_SELECTIONINVALIDATED);
     if(ready->selectedIndex>=0&&canRaise(p)){
       LeafItemProvider *selected=newItem(p,ready->selectedIndex);
       if(selected){
         apiEvent(&selected->simple,LEAF_UIA_EVENT_SELECTEDITEM);
         itemRelease(&selected->simple);
       }
     }
   }
 } else {
   TRACE("evt-structure-first");
   raiseStructure(p,LeafStructureChildrenBulkAdded);
   TRACE("evt-structure-first-done");
 }
 TRACE("publish-events-done");
 /* Retire only after the comparison used it; readers may still hold it. */
 retireSnapshot(p,previous);
 reclaimRetired(p);
 TRACE("publish-retired");
 *changed=different;
 p->flushing=0;
 provRelease(&p->simple);
 return S_OK;
}

/* ------------------------------- lifecycle -------------------------------- */

int32_t leaf_select_context_new(LeafSelectContext **out){
 if(!out)return E_POINTER;
 *out=NULL;
 HRESULT hr=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
 if(FAILED(hr)&&hr!=RPC_E_CHANGED_MODE)return hr;
 int initialized=SUCCEEDED(hr);
 if(!InitOnceExecuteOnce(&apiOnce,loadApi,NULL,NULL)){
   hr=HRESULT_FROM_WIN32(GetLastError());
   if(initialized)CoUninitialize();
   return hr;
 }
 LeafSelectContext *c=(LeafSelectContext*)calloc(1,sizeof(*c));
 if(!c){if(initialized)CoUninitialize();return E_OUTOFMEMORY;}
 c->refs=1;c->owner=GetCurrentThreadId();c->initialized=initialized;
 InitializeSRWLock(&c->requestLock);
 InitializeSRWLock(&c->linkLock);
 c->requestKind=LEAF_SELECT_REQUEST_NONE;
 *out=c;return S_OK;
}
int32_t leaf_select_context_set_wake(LeafSelectContext *c,void *window,uint32_t message){
 HRESULT hr=owner(c);
 if(FAILED(hr))return hr;
 if(window){
   HWND w=(HWND)window;
   if(!IsWindow(w))return E_INVALIDARG;
   if(GetWindowThreadProcessId(w,NULL)!=c->owner)return RPC_E_WRONG_THREAD;
   if(message<0x8000u||message>0xbfffu)return E_INVALIDARG;
 }
 c->wake=window?(HWND)window:NULL;
 c->wakeMessage=window?(UINT)message:0;
 return S_OK;
}
static int32_t newProvider(LeafSelectContext *c,void *window,int kind,LeafProvider **out){
 if(!out)return E_POINTER;
 *out=NULL;
 HRESULT hr=owner(c);
 if(FAILED(hr))return hr;
 if(!window||!IsWindow((HWND)window))return E_INVALIDARG;
 if(GetWindowThreadProcessId((HWND)window,NULL)!=c->owner)return RPC_E_WRONG_THREAD;
 LeafProvider *p=(LeafProvider*)calloc(1,sizeof(*p));
 if(!p)return E_OUTOFMEMORY;
 p->simple.lpVtbl=&provSimpleVtbl;
 p->fragment.lpVtbl=&provFragmentVtbl;
 p->root.lpVtbl=&provRootVtbl;
 p->expand.lpVtbl=&provExpandVtbl;
 p->value.lpVtbl=&provValueVtbl;
 p->selection.lpVtbl=&provSelectionVtbl;
 p->refs=1;p->context=c;p->window=(HWND)window;p->kind=kind;p->id=(int)(INT_PTR)p;
#ifdef LEAF_SELECT_PROVIDER_PROBES
 /* Logical provider identity for tests: monotonic, independent of the heap
    address (the allocator may legally reuse a freed address). */
 p->probeIdentity=InterlockedIncrement64(&probeIdentitySeq);
#endif
#ifdef LEAF_SELECT_PROVIDER_PROBES
 {char message[160];wsprintfA(message,"new-provider kind=%d tid=%lu ctx=%p owner=%lu win=%p",
   kind,(unsigned long)GetCurrentThreadId(),(void*)c,(unsigned long)c->owner,(void*)window);traceTo(message);}
#endif
 p->windowLive=1;
 InitializeSRWLock(&p->lock);
 InterlockedIncrement(&c->refs);
 InterlockedIncrement(&c->objects);
 hr=apiHost(p->window,&p->host);
 if(FAILED(hr)){provRelease(&p->simple);return hr;}
 c->owned++;
 *out=p;
 return S_OK;
}
int32_t leaf_select_trigger_new(LeafSelectContext *c,void *window,LeafProvider **out){
 return newProvider(c,window,1,out);
}
int32_t leaf_select_popup_new(LeafSelectContext *c,void *window,LeafProvider **out){
 return newProvider(c,window,2,out);
}
int32_t leaf_select_link(LeafProvider *trigger,LeafProvider *popup){
 if(!trigger||!popup)return E_POINTER;
 if(trigger->kind!=1||popup->kind!=2)return E_INVALIDARG;
 if(trigger->context!=popup->context)return E_INVALIDARG;
 LeafSelectContext *c=trigger->context;
 if(GetCurrentThreadId()!=c->owner)return RPC_E_WRONG_THREAD;
 AcquireSRWLockExclusive(&c->linkLock);
 trigger->popup=popup;
 popup->trigger=trigger;
 ReleaseSRWLockExclusive(&c->linkLock);
 return S_OK;
}
int32_t leaf_select_stage(LeafProvider *p,int32_t open,int32_t enabled,
                          const uint16_t *name,const uint16_t *value,
                          const LeafSelectItem *items,int32_t count,int32_t selectedIndex,
                          int32_t focused,int32_t visible,int32_t firstRow,int32_t rows,
                          int32_t rowHeightPx){
 HRESULT hr=writable(p);
 if(FAILED(hr)){
#ifdef LEAF_SELECT_PROVIDER_PROBES
   char message[160];
   wsprintfA(message,"stage-refused hr=0x%08lx now=%lu owner=%lu kind=%d closed=%d ctx=%p refs=%ld",
     (unsigned long)hr,(unsigned long)GetCurrentThreadId(),
     (unsigned long)(p->context?p->context->owner:0),p->kind,
     p->context?p->context->closed:-1,(void*)p->context,
     (long)(p->context?p->context->refs:0));
   traceTo(message);
#endif
   return hr;
 }
 if(count<0)return E_INVALIDARG;
 LeafSnapshot *accepted=p->ready?p->ready:p->published;
 if(sameSnapshot(accepted,name,value,items,count,open,enabled,selectedIndex,focused,
                 visible,firstRow,rows,rowHeightPx)){
   freeSnapshots(p->staged);p->staged=NULL;
   return S_OK;
 }
 LeafSnapshot *s=copySnapshot(name,value,items,count,selectedIndex,open,enabled,focused,
                              visible,firstRow,rows,rowHeightPx);
 if(!s)return E_OUTOFMEMORY;
 freeSnapshots(p->staged);
 p->staged=s;
 return S_OK;
}
void leaf_select_accept(LeafProvider *p){
 if(!p||!p->staged)return;
 p->staged->next=p->ready;
 p->ready=p->staged;
 p->staged=NULL;
}
void leaf_select_discard(LeafProvider *p){
 if(FAILED(writable(p)))return;
 freeSnapshots(p->staged);
 p->staged=NULL;
}
void leaf_select_trace_w(const char *tag,void *window,intptr_t lparam,uintptr_t wparam){
#ifdef LEAF_SELECT_PROVIDER_PROBES
 char message[256];
 wsprintfA(message,"%s win=%p lp=%ld wp=%lu",tag,window,(long)lparam,(unsigned long)wparam);
 traceTo(message);
#else
 (void)tag;(void)window;(void)lparam;(void)wparam;
#endif
}
intptr_t leaf_select_get_object(LeafProvider *p,uintptr_t wparam,intptr_t lparam){
#ifdef LEAF_SELECT_PROVIDER_PROBES
 {
  char message[256];WCHAR text[64]={0};
  if(p->window)GetWindowTextW(p->window,text,63);
  wsprintfA(message,"getobject-enter kind=%d id=%d win=%p text=%ls wp=%lu lp=%ld",
    p->kind,p->id,(void*)p->window,text,(unsigned long)wparam,(long)lparam);
  traceTo(message);
 }
#endif
 if((LONG)lparam!=-25||FAILED(writable(p))||!p->publishedFlag)return 0;
 /* UIA can re-enter this window with WM_GETOBJECT while the outer
    UiaReturnRawElementProvider call is still on the stack (observed with
    wParam 0). Answering recursively deadlocks the UI thread, so the nested
    request is refused and the outer call keeps ownership. */
 if(p->returning){ TRACE("getobject-nested-refused"); return 0; }
 /* wParam 0 is used by UIA for a window/auxiliary connection; it must be
    answered too, but never while an outer UiaReturnRawElementProvider call for
    the same provider is still on the stack (that recursion deadlocks). */
 p->returning=1;
 InterlockedExchange(&p->exposed,1);
 LRESULT answer=apiReturn(p->window,(WPARAM)wparam,(LPARAM)lparam,&p->simple);
 p->returning=0;
#ifdef LEAF_SELECT_PROVIDER_PROBES
 {
  char message[128];
  wsprintfA(message,"getobject-done answer=%ld err=%lu",(long)answer,(unsigned long)GetLastError());
  traceTo(message);
 }
#endif
 return answer;
}
int32_t leaf_select_detach(LeafProvider **slot){
 if(!slot)return E_POINTER;
 if(!*slot)return S_OK;
 LeafProvider *p=(LeafProvider*)*slot;
 HRESULT hr=writable(p);
 if(FAILED(hr))return hr;
 InterlockedExchange(&p->windowLive,0);
 InterlockedExchange(&p->publishedFlag,0);
 LeafSnapshot *current=(LeafSnapshot*)InterlockedExchangePointer(
   (PVOID volatile*)&p->published,NULL);
 retireSnapshot(p,current);
 reclaimRetired(p);
 unlinkPeer(p);
 *slot=NULL;
 p->context->owned--;
 LeafSelectContext *c=p->context;
 int first=c->retired==NULL;
 p->retiredNext=c->retired;
 c->retired=p;
 if(first&&c->wake)PostMessageW(c->wake,c->wakeMessage,0,0);
 return S_OK;
}
static HRESULT disconnectingCall(LeafProvider *p){
 if(!p)return E_POINTER;
 if(apiDisconnect)return apiDisconnect(&p->simple);
 return S_OK;
}
int32_t leaf_select_drain(LeafSelectContext *c){
 HRESULT hr=owner(c);
 if(FAILED(hr))return hr;
 if(c->draining)return E_UNEXPECTED;
 if(InSendMessageEx(NULL)&(ISMEX_SEND|ISMEX_NOTIFY|ISMEX_CALLBACK))
   return RPC_E_CANTCALLOUT_ININPUTSYNCCALL;
 c->draining=1;
 while(c->retired){
   LeafProvider *p=c->retired;
   c->retired=p->retiredNext;
   p->retiredNext=NULL;
   InterlockedExchange(&p->disconnecting,InterlockedCompareExchange(&p->exposed,0,0));
   HRESULT disconnect=disconnectingCall(p);
   InterlockedExchange(&p->disconnecting,0);
   if(FAILED(disconnect)){
     p->retiredNext=c->retired;
     c->retired=p;
     c->draining=0;
     return disconnect;
   }
   provRelease(&p->simple);
 }
 c->draining=0;
 return S_OK;
}
int32_t leaf_select_context_close(LeafSelectContext **slot){
 if(!slot)return E_POINTER;
 if(!*slot)return S_OK;
 LeafSelectContext *c=*slot;
 HRESULT hr=owner(c);
 if(FAILED(hr))return hr;
 if(c->draining)return E_UNEXPECTED;
 if(c->owned)return E_UNEXPECTED;
 hr=leaf_select_drain(c);
 if(FAILED(hr))return hr;
 c->closed=1;
 *slot=NULL;
 if(c->initialized)CoUninitialize();
 contextRelease(c);
 return S_OK;
}
void leaf_select_counts(LeafSelectContext *c,int32_t *owned,int32_t *objects){
 if(owned)*owned=c?c->owned:0;
 if(objects)*objects=c?(int32_t)InterlockedCompareExchange(&c->objects,0,0):0;
}
void leaf_select_clear_request(LeafSelectContext *c){
 if(!c||c->closed)return;
 AcquireSRWLockExclusive(&c->requestLock);
 c->requestKind=LEAF_SELECT_REQUEST_NONE;
 c->requestWindow=NULL;
 ReleaseSRWLockExclusive(&c->requestLock);
}
int32_t leaf_select_take_request(LeafSelectContext *c,void *window1,void *window2,
                                 int32_t *kind,int32_t *index,int32_t *generation,
                                 void **window){
 if(!c||!kind||!index||!generation||!window)return E_POINTER;
 *kind=LEAF_SELECT_REQUEST_NONE;*index=0;*generation=0;*window=NULL;
 if(c->closed)return ELEMENT_GONE;
 AcquireSRWLockExclusive(&c->requestLock);
 if(c->requestKind!=LEAF_SELECT_REQUEST_NONE&&
    (c->requestWindow==(HWND)window1||c->requestWindow==(HWND)window2)){
   *kind=c->requestKind;
   *index=c->requestIndex;
   *generation=c->requestGeneration;
   *window=c->requestWindow;
   c->requestWindow=NULL;
   c->requestKind=LEAF_SELECT_REQUEST_NONE;
 }
 ReleaseSRWLockExclusive(&c->requestLock);
 return S_OK;
}
int32_t leaf_select_reclaim(LeafProvider *p){
 if(!p)return E_POINTER;
 HRESULT hr=owner(p->context);
 if(FAILED(hr))return hr;
 reclaimRetired(p);
 return S_OK;
}
int32_t leaf_select_generation(LeafProvider *p){
 if(!p)return 0;
 return (int32_t)InterlockedCompareExchange(&p->generation,0,0);
}
int32_t leaf_select_window_live(LeafProvider *p){
 if(!p)return 0;
 return p->windowLive?1:0;
}

#ifdef LEAF_SELECT_PROVIDER_PROBES
/* Controlled-concurrency probes: they drive the real read functions so a test
   can pause a reader after it acquired its snapshot and let the owner publish. */
int32_t leaf_select_probe_arm(LeafProvider *p){
 if(!p)return E_POINTER;
 if(!p->probeEntered)p->probeEntered=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probeRelease)p->probeRelease=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probeEntered||!p->probeRelease)return E_OUTOFMEMORY;
 ResetEvent(p->probeEntered);
 ResetEvent(p->probeRelease);
 InterlockedExchange(&p->probeArmed,1);
 return S_OK;
}
int32_t leaf_select_probe_wait_entered(LeafProvider *p,int32_t timeoutMs){
 if(!p||!p->probeEntered)return 0;
 return WaitForSingleObject(p->probeEntered,(DWORD)timeoutMs)==WAIT_OBJECT_0?1:0;
}
void leaf_select_probe_release(LeafProvider *p){
 if(!p||!p->probeRelease)return;
 SetEvent(p->probeRelease);
 InterlockedExchange(&p->probeArmed,0);
}
int32_t leaf_select_probe_measure_value(LeafProvider *p){
 if(!p)return -1;
 LeafSnapshot *snapshot=readGuardEnter(p);
 int length=-1;
 if(snapshot)length=snapshot->value?(int)wcslen(snapshot->value):0;
 readGuardExit(p);
 return length;
}
int32_t leaf_select_probe_navigate_child(LeafProvider *p){
 if(!p)return -1;
 LeafUiaFragment *child=NULL;
 HRESULT hr=provNavigate(&p->fragment,LeafNavigateFirstChild,&child);
 if(FAILED(hr))return -1;
 int result=0;
 if(child){
   LeafUiaFragment *parentFragment=NULL;
   if(SUCCEEDED(child->lpVtbl->Navigate(child,LeafNavigateParent,&parentFragment)))result=parentFragment!=NULL?1:0;
   if(parentFragment)parentFragment->lpVtbl->Release(parentFragment);
   child->lpVtbl->Release(child);
 }
 return result;
}
int32_t leaf_select_probe_set_value(LeafProvider *p){
 if(!p)return E_POINTER;
 return (int32_t)provSetValue(&p->value,L"probe");
}
void leaf_select_probe_counts(int32_t *live,int32_t *allocated,int32_t *freed,int32_t *readers,LeafProvider *p){
 LONG64 a=InterlockedCompareExchange64(&probeAllocated,0,0);
 LONG64 f=InterlockedCompareExchange64(&probeFreed,0,0);
 if(allocated)*allocated=(int32_t)a;
 if(freed)*freed=(int32_t)f;
 if(live)*live=(int32_t)(a-f);
 if(readers)*readers=p?(int32_t)InterlockedCompareExchange(&p->readers,0,0):0;
}
#endif

#ifdef LEAF_SELECT_PROVIDER_PROBES
int32_t leaf_select_probe_arm_exit(LeafProvider *p){
 if(!p)return E_POINTER;
 if(!p->probeExitEntered)p->probeExitEntered=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probeExitRelease)p->probeExitRelease=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probeExitEntered||!p->probeExitRelease)return E_OUTOFMEMORY;
 ResetEvent(p->probeExitEntered);
 ResetEvent(p->probeExitRelease);
 InterlockedExchange(&p->probeExitArmed,1);
 return S_OK;
}
int32_t leaf_select_probe_wait_exit(LeafProvider *p,int32_t timeoutMs){
 if(!p||!p->probeExitEntered)return 0;
 return WaitForSingleObject(p->probeExitEntered,(DWORD)timeoutMs)==WAIT_OBJECT_0?1:0;
}
void leaf_select_probe_release_exit(LeafProvider *p){
 if(!p||!p->probeExitRelease)return;
 SetEvent(p->probeExitRelease);
 InterlockedExchange(&p->probeExitArmed,0);
}
#endif

#ifdef LEAF_SELECT_PROVIDER_PROBES
int32_t leaf_select_probe_arm_drain(LeafProvider *p){
 if(!p)return E_POINTER;
 if(!p->probeDrainEntered)p->probeDrainEntered=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probeDrainRelease)p->probeDrainRelease=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probeDrainEntered||!p->probeDrainRelease)return E_OUTOFMEMORY;
 ResetEvent(p->probeDrainEntered);
 ResetEvent(p->probeDrainRelease);
 InterlockedExchange(&p->probeDrainArmed,1);
 return S_OK;
}
int32_t leaf_select_probe_wait_drain(LeafProvider *p,int32_t timeoutMs){
 if(!p||!p->probeDrainEntered)return 0;
 return WaitForSingleObject(p->probeDrainEntered,(DWORD)timeoutMs)==WAIT_OBJECT_0?1:0;
}
void leaf_select_probe_release_drain(LeafProvider *p){
 if(!p||!p->probeDrainRelease)return;
 SetEvent(p->probeDrainRelease);
 InterlockedExchange(&p->probeDrainArmed,0);
}
#endif

#ifdef LEAF_SELECT_PROVIDER_PROBES
int32_t leaf_select_probe_arm_peer(LeafProvider *p){
 if(!p)return E_POINTER;
 if(!p->probePeerEntered)p->probePeerEntered=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probePeerRelease)p->probePeerRelease=CreateEventW(NULL,TRUE,FALSE,NULL);
 if(!p->probePeerEntered||!p->probePeerRelease)return E_OUTOFMEMORY;
 ResetEvent(p->probePeerEntered);
 ResetEvent(p->probePeerRelease);
 InterlockedExchange(&p->probePeerArmed,1);
 return S_OK;
}
int32_t leaf_select_probe_wait_peer(LeafProvider *p,int32_t timeoutMs){
 if(!p||!p->probePeerEntered)return 0;
 return WaitForSingleObject(p->probePeerEntered,(DWORD)timeoutMs)==WAIT_OBJECT_0?1:0;
}
void leaf_select_probe_release_peer(LeafProvider *p){
 if(!p||!p->probePeerRelease)return;
 SetEvent(p->probePeerRelease);
 InterlockedExchange(&p->probePeerArmed,0);
}
int32_t leaf_select_probe_peer_freed(LeafProvider *p){
 return p?(int32_t)InterlockedCompareExchange(&p->probePeerFreed,0,0):-1;
}
#endif

#ifdef LEAF_SELECT_PROVIDER_PROBES
void leaf_select_probe_publish_counts(int32_t *published,int32_t *reclaims,int32_t *mismatch){
 if(published)*published=(int32_t)InterlockedCompareExchange64(&probePublished,0,0);
 if(reclaims)*reclaims=(int32_t)InterlockedCompareExchange64(&probeReclaims,0,0);
 if(mismatch)*mismatch=(int32_t)InterlockedCompareExchange(&probeMismatch,0,0);
}
#endif

#ifdef LEAF_SELECT_PROVIDER_PROBES
int64_t leaf_select_probe_identity(LeafProvider *p){
 return p?InterlockedCompareExchange64(&p->probeIdentity,0,0):0;
}
int32_t leaf_select_probe_freed_providers(void){
 return (int32_t)InterlockedCompareExchange(&probeFreedProviders,0,0);
}
#endif
