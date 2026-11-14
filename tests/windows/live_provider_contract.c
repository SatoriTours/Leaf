#define COBJMACROS
#include <windows.h>
#include <uiautomationcore.h>
#include <stdio.h>
#include "../../src/leaf/backends/win32/live_provider.h"
#define NOT_AVAILABLE ((HRESULT)0x80040201L)
#define E_NOT_EXPECTED ((HRESULT)0x8000ffffL)
#define CHECK(x) do { if(!(x)){printf("live provider contract failed line %d: %s\n",__LINE__,#x);result=__LINE__;goto cleanup;} } while(0)
static int property(IRawElementProviderSimple *p,int id,int expected) {
 VARIANT v;VariantInit(&v);HRESULT hr=IRawElementProviderSimple_GetPropertyValue(p,id,&v);
 int ok=SUCCEEDED(hr)&&v.vt==VT_I4&&v.lVal==expected;VariantClear(&v);return ok;
}
static int nameIs(IRawElementProviderSimple *p,const WCHAR *expected) {
 VARIANT v;VariantInit(&v);HRESULT hr=IRawElementProviderSimple_GetPropertyValue(p,30005,&v);
 int ok=SUCCEEDED(hr)&&v.vt==VT_BSTR&&wcscmp(v.bstrVal,expected)==0;VariantClear(&v);return ok;
}
struct ThreadCheck {LeafLiveProvider *p;HRESULT stage;int read;};
static DWORD WINAPI otherThread(void *data){struct ThreadCheck *t=data;t->stage=leaf_live_stage(t->p,1,L"wrong thread");t->read=nameIs((IRawElementProviderSimple*)t->p,L"Accepted alert");return 0;}
#ifdef LEAF_LIVE_PROVIDER_PROBES
/* Owner-thread re-entrancy, notification exposure and flush-tombstone contracts.
   The seam fakes only the UIAutomationCore boundary; the ownership code under
   test is the shipping code. Each contract covers one ownership risk so a
   failure points at a single defect. */
static LeafLiveContext *probeContext;
static LeafLiveProvider *probePending;
static int disconnectCalls,eventCalls,propertyCalls;
static HRESULT reentrantDrain,reentrantClose;
static void resetProbes(void){
 disconnectCalls=eventCalls=propertyCalls=0;reentrantDrain=reentrantClose=0;probePending=NULL;probeContext=NULL;
}
static HWND probeWindow(void){
 return CreateWindowExW(0,L"STATIC",L"Live provider probe",WS_POPUP,0,0,240,40,NULL,NULL,GetModuleHandleW(NULL),NULL);
}
static LRESULT WINAPI probeReturn(HWND window,WPARAM wp,LPARAM lp,IRawElementProviderSimple *provider){
 (void)window;(void)wp;(void)lp;(void)provider;return 0;
}
static HRESULT WINAPI countDisconnect(IRawElementProviderSimple *provider){(void)provider;disconnectCalls++;return S_OK;}
static HRESULT WINAPI countEvent(IRawElementProviderSimple *provider,EVENTID id){(void)provider;(void)id;eventCalls++;return S_OK;}
static HRESULT WINAPI countProperty(IRawElementProviderSimple *provider,PROPERTYID id,VARIANT before,VARIANT after){
 (void)provider;(void)id;(void)before;(void)after;propertyCalls++;return S_OK;
}
static BOOL WINAPI probeListening(void){return TRUE;}
/* A: UIA may retire another binding while one is being disconnected. The node
   enqueued by that re-entrant detach must not be overwritten by the pop. */
static HRESULT WINAPI detachReentrantDisconnect(IRawElementProviderSimple *provider){
 (void)provider;disconnectCalls++;
 if(disconnectCalls==1&&probePending){
  LeafLiveProvider *pending=probePending;probePending=NULL;
  leaf_live_detach(&pending);
 }
 return S_OK;
}
static int retiredReentrancyContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *first=NULL,*second=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={detachReentrantDisconnect,NULL,NULL,NULL,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"First binding",&first)));leaf_live_accept(first);
 CHECK(SUCCEEDED(leaf_live_flush(first,&changed))&&changed==1);
 CHECK(leaf_live_get_object(first,0,-25)==0);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,2,L"Second binding",&second)));leaf_live_accept(second);
 CHECK(SUCCEEDED(leaf_live_flush(second,&changed))&&changed==1);
 CHECK(leaf_live_get_object(second,0,-25)==0);
 probeContext=ctx;probePending=second;
 CHECK(SUCCEEDED(leaf_live_detach(&first))&&first==NULL);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 leaf_live_counts(ctx,&owned,&objects);
 printf("A retired re-entrancy: disconnects=%d owned=%d objects=%d\n",disconnectCalls,owned,objects);
 CHECK(disconnectCalls==2);
 CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);probePending=NULL;probeContext=NULL;
 if(first)leaf_live_detach(&first);
 if(second)leaf_live_detach(&second);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
/* B: a nested drain from a provider callback must be refused, not walked. */
static HRESULT WINAPI drainReentrantDisconnect(IRawElementProviderSimple *provider){
 (void)provider;disconnectCalls++;
 if(disconnectCalls==1)reentrantDrain=leaf_live_drain(probeContext);
 return S_OK;
}
static int reentrantDrainContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={drainReentrantDisconnect,NULL,NULL,NULL,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Re-entrant drain",&p)));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(leaf_live_get_object(p,0,-25)==0);
 probeContext=ctx;
 CHECK(SUCCEEDED(leaf_live_detach(&p))&&p==NULL);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 printf("B re-entrant drain: hr=%08lX disconnects=%d\n",(unsigned long)reentrantDrain,disconnectCalls);
 CHECK(reentrantDrain==E_NOT_EXPECTED);
 CHECK(disconnectCalls==1);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);probeContext=NULL;
 if(p)leaf_live_detach(&p);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
/* C: a nested close must not free a context another frame is draining. */
static HRESULT WINAPI closeReentrantDisconnect(IRawElementProviderSimple *provider){
 (void)provider;disconnectCalls++;
 if(disconnectCalls==1)reentrantClose=leaf_live_context_close(&probeContext);
 return S_OK;
}
static int reentrantCloseContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={closeReentrantDisconnect,NULL,NULL,NULL,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Re-entrant close",&p)));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(leaf_live_get_object(p,0,-25)==0);
 probeContext=ctx;
 CHECK(SUCCEEDED(leaf_live_detach(&p))&&p==NULL);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 printf("C re-entrant close: hr=%08lX context=%p disconnects=%d\n",(unsigned long)reentrantClose,(void*)probeContext,disconnectCalls);
 CHECK(reentrantClose==E_NOT_EXPECTED);
 CHECK(probeContext!=NULL); /* the refused close must leave the context usable */
 CHECK(disconnectCalls==1);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);probeContext=NULL;
 if(p)leaf_live_detach(&p);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
/* D: a notification hands the provider to UIA without WM_GETOBJECT; that still
   creates the disconnect obligation on retirement. */
static int notificationExposureContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={countDisconnect,countEvent,countProperty,probeListening,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);ShowWindow(w,5);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Notify only",&p)));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 printf("D notification exposure: exposed=%d events=%d properties=%d\n",leaf_live_probe_exposed(p),eventCalls,propertyCalls);
 CHECK(eventCalls==1&&propertyCalls==0);
 CHECK(leaf_live_probe_exposed(p)==1);
 CHECK(SUCCEEDED(leaf_live_detach(&p))&&p==NULL);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 CHECK(disconnectCalls==1);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);
 if(p)leaf_live_detach(&p);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
/* E: a detach from inside flush must not free the in-use snapshot and must stop
   the remaining notifications instead of publishing to a tombstoned provider. */
static HRESULT WINAPI detachProperty(IRawElementProviderSimple *provider,PROPERTYID id,VARIANT before,VARIANT after){
 (void)provider;(void)id;(void)before;(void)after;propertyCalls++;
 if(propertyCalls==1&&probePending){LeafLiveProvider *pending=probePending;probePending=NULL;leaf_live_detach(&pending);}
 return S_OK;
}
static int flushDetachContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={countDisconnect,countEvent,detachProperty,probeListening,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);ShowWindow(w,5);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Before",&p)));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(eventCalls==1&&propertyCalls==0);
 CHECK(SUCCEEDED(leaf_live_stage(p,1,L"After")));
 leaf_live_accept(p);probePending=p;
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 leaf_live_counts(ctx,&owned,&objects);
 printf("E flush detach: properties=%d events=%d owned=%d objects=%d\n",propertyCalls,eventCalls,owned,objects);
 CHECK(propertyCalls==1&&eventCalls==1); /* name notified, live event stopped */
 CHECK(owned==0&&objects==1);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 CHECK(disconnectCalls==1);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);probePending=NULL;
 if(p)leaf_live_detach(&p);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
/* F: same Name, changed kind. A detach inside the LiveSetting notification must
   stop the remaining ControlType/LocalizedControlType notifications and the
   LiveRegionChanged event. */
static HRESULT WINAPI detachOnLiveProperty(IRawElementProviderSimple *provider,PROPERTYID id,VARIANT before,VARIANT after){
 (void)provider;(void)before;(void)after;propertyCalls++;
 if(id==30135&&propertyCalls==1&&probePending){LeafLiveProvider *pending=probePending;probePending=NULL;leaf_live_detach(&pending);}
 return S_OK;
}
static int flushDetachLiveContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={countDisconnect,countEvent,detachOnLiveProperty,probeListening,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);ShowWindow(w,5);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Same name",&p)));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(eventCalls==1&&propertyCalls==0);
 CHECK(SUCCEEDED(leaf_live_stage(p,2,L"Same name")));
 leaf_live_accept(p);probePending=p;
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 leaf_live_counts(ctx,&owned,&objects);
 printf("F detach on LiveSetting: properties=%d events=%d owned=%d objects=%d\n",propertyCalls,eventCalls,owned,objects);
 CHECK(propertyCalls==1&&eventCalls==1);
 CHECK(owned==0&&objects==1);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 CHECK(disconnectCalls==1);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);probePending=NULL;
 if(p)leaf_live_detach(&p);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
/* G: same as F but the detach happens inside the ControlType notification, so
   LocalizedControlType and the LiveRegionChanged event must be suppressed. */
static HRESULT WINAPI detachOnControlTypeProperty(IRawElementProviderSimple *provider,PROPERTYID id,VARIANT before,VARIANT after){
 (void)provider;(void)before;(void)after;propertyCalls++;
 if(id==30003&&propertyCalls==2&&probePending){LeafLiveProvider *pending=probePending;probePending=NULL;leaf_live_detach(&pending);}
 return S_OK;
}
static int flushDetachControlTypeContract(void){
 int result=0,changed=0,owned=-1,objects=-1;
 LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;HWND w=NULL;
 LeafLiveProbeHooks hooks={countDisconnect,countEvent,detachOnControlTypeProperty,probeListening,probeReturn};
 resetProbes();
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 leaf_live_probe_hooks(&hooks);
 w=probeWindow();CHECK(w!=NULL);ShowWindow(w,5);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Same name",&p)));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(eventCalls==1&&propertyCalls==0);
 CHECK(SUCCEEDED(leaf_live_stage(p,2,L"Same name")));
 leaf_live_accept(p);probePending=p;
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 leaf_live_counts(ctx,&owned,&objects);
 printf("G detach on ControlType: properties=%d events=%d owned=%d objects=%d\n",propertyCalls,eventCalls,owned,objects);
 CHECK(propertyCalls==2&&eventCalls==1);
 CHECK(owned==0&&objects==1);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 CHECK(disconnectCalls==1);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
cleanup:
 leaf_live_probe_hooks(NULL);probePending=NULL;
 if(p)leaf_live_detach(&p);
 if(ctx){leaf_live_drain(ctx);leaf_live_context_close(&ctx);}
 if(w)DestroyWindow(w);
 return result;
}
#endif
int run_live_provider_contract(void) {
 int result=0,changed=0,owned=-1,objects=-1;LeafLiveContext *ctx=NULL;LeafLiveProvider *p=NULL;
 IRawElementProviderSimple *held=NULL;HWND w=NULL;HANDLE worker=NULL;VARIANT v;
 CHECK(SUCCEEDED(leaf_live_context_new(&ctx)));
 w=CreateWindowExW(0,L"STATIC",L"Live provider contract",WS_POPUP,0,0,200,40,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(w!=NULL);
 CHECK(FAILED(leaf_live_create(ctx,w,0,L"Invalid kind",&p))&&p==NULL);
 CHECK(SUCCEEDED(leaf_live_create(ctx,w,1,L"Loading",&p)));
 held=(IRawElementProviderSimple*)p;IRawElementProviderSimple_AddRef(held);
 VariantInit(&v);CHECK(IRawElementProviderSimple_GetPropertyValue(held,30005,&v)==NOT_AVAILABLE);
 CHECK(FAILED(leaf_live_context_close(&ctx))&&ctx!=NULL);
 leaf_live_accept(p);CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(nameIs(held,L"Loading")&&property(held,30135,1)&&property(held,30003,50017));
 CHECK(SUCCEEDED(leaf_live_stage(p,1,L"Loading")));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==0);
 CHECK(SUCCEEDED(leaf_live_stage(p,1,L"Accepted pending")));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_stage(p,2,L"Rejected alert")));leaf_live_discard(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1&&nameIs(held,L"Accepted pending"));
 CHECK(SUCCEEDED(leaf_live_stage(p,2,L"Accepted alert")));leaf_live_accept(p);
 CHECK(SUCCEEDED(leaf_live_flush(p,&changed))&&changed==1);
 CHECK(nameIs(held,L"Accepted alert")&&property(held,30135,2)&&property(held,30003,50026));
 WCHAR bad[]={0xd800,0};CHECK(FAILED(leaf_live_stage(p,1,bad))&&nameIs(held,L"Accepted alert"));
 struct ThreadCheck thread={p,0,0};worker=CreateThread(NULL,0,otherThread,&thread,0,NULL);CHECK(worker!=NULL);
 CHECK(WaitForSingleObject(worker,5000)==WAIT_OBJECT_0);CHECK(thread.stage==(HRESULT)0x8001010eL&&thread.read==1);
 CloseHandle(worker);worker=NULL;
 CHECK(SUCCEEDED(leaf_live_detach(&p))&&p==NULL);
 CHECK(SUCCEEDED(leaf_live_drain(ctx)));
 VariantInit(&v);CHECK(IRawElementProviderSimple_GetPropertyValue(held,30005,&v)==NOT_AVAILABLE);
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==1);
 IRawElementProviderSimple_Release(held);held=NULL;
 leaf_live_counts(ctx,&owned,&objects);CHECK(owned==0&&objects==0);
 CHECK(SUCCEEDED(leaf_live_detach(&p)));
 CHECK(SUCCEEDED(leaf_live_context_close(&ctx))&&ctx==NULL);
cleanup:
 if(worker){if(WaitForSingleObject(worker,5000)!=WAIT_OBJECT_0)ExitProcess(result?result:99);CloseHandle(worker);}
 if(p)leaf_live_detach(&p);
 if(held)IRawElementProviderSimple_Release(held);
 if(w)DestroyWindow(w);
 if(ctx)leaf_live_context_close(&ctx);
#ifdef LEAF_LIVE_PROVIDER_PROBES
 if(!result)result=retiredReentrancyContract();
 if(!result)result=reentrantDrainContract();
 if(!result)result=reentrantCloseContract();
 if(!result)result=notificationExposureContract();
 if(!result)result=flushDetachContract();
 if(!result)result=flushDetachLiveContract();
 if(!result)result=flushDetachControlTypeContract();
#else
 printf("live provider owner re-entrancy probes are not compiled in\n");
 if(!result)result=98;
#endif
 return result;
}
