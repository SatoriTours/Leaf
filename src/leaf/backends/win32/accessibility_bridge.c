// Dynamic Annotation augments the Windows proxy; it is not a Leaf UIA provider.
#include "accessibility_bridge.h"
#define COBJMACROS
#include <windows.h>
#include <oleacc.h>
#include <stdlib.h>

// Public Windows SDK property identifiers (absent from older MinGW headers):
// microsoft/win32metadata: generation/WinSDK/RecompiledIdlHeaders/um/UIAutomationCoreApi.h
static const GUID properties[] = {
  {0xc3a6921b,0x4a99,0x44f1,{0xbc,0xa6,0x61,0x18,0x70,0x52,0xc4,0x31}}, // Name
  {0x08555685,0x0977,0x45c7,{0xa7,0xa6,0xab,0xaf,0x56,0x84,0x12,0x1a}}, // HelpText
  {0x608d3df8,0x8128,0x4aa7,{0xa4,0x28,0xf5,0x5e,0x49,0x26,0x72,0x91}}, // MSAA Name
  {0x4d48dfe4,0xbd3f,0x491f,{0xa6,0x48,0x49,0x2d,0x6f,0x20,0xc5,0x88}} // MSAA Description
};
static const GUID servicesClass = {0xb5f8350b,0x0548,0x48b1,{0xa6,0xee,0x88,0xbd,0x00,0xb4,0xa5,0xe7}};
static const GUID servicesInterface = {0x6e26e776,0x04f0,0x495d,{0x80,0xe4,0x33,0x30,0x35,0x2e,0x31,0x69}};
struct LeafAnnotations {
  IAccPropServices *services;
  int uninitialize;
};
int32_t leaf_annotations_new(LeafAnnotations **output) {
  if (!output) return E_POINTER;
  *output=NULL;
  HRESULT hr=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
  // Respect an existing COM apartment; never change the application's model.
  if (FAILED(hr) && hr!=RPC_E_CHANGED_MODE) return hr;
  int initialized=SUCCEEDED(hr);
  LeafAnnotations *a=calloc(1,sizeof(*a));
  if (!a) { if(initialized)CoUninitialize(); return E_OUTOFMEMORY; }
  a->uninitialize=initialized;
  hr=CoCreateInstance(&servicesClass,NULL,CLSCTX_INPROC_SERVER,&servicesInterface,(void**)&a->services);
  if (FAILED(hr)) { leaf_annotations_release(a); return hr; }
  *output=a;
  return S_OK;
}
void leaf_annotations_release(LeafAnnotations *a) {
  if (!a) return;
  if (a->services) IAccPropServices_Release(a->services);
  if (a->uninitialize) CoUninitialize();
  free(a);
}
int32_t leaf_annotations_clear(LeafAnnotations *a,void *window,uint32_t *mask) {
  if (!a || !window || !mask) return E_INVALIDARG;
  if (!*mask)return S_OK;
  GUID owned[4];int count=0;
  for(int i=0;i<4;i++)if(*mask&(1u<<i))owned[count++]=properties[i];
  HRESULT hr=IAccPropServices_ClearHwndProps(a->services,(HWND)window,OBJID_CLIENT,CHILDID_SELF,owned,count);
  if(SUCCEEDED(hr))*mask=0;
  return hr;
}
static HRESULT setString(LeafAnnotations *a,HWND w,int i,const uint16_t *s) {
  return IAccPropServices_SetHwndPropStr(a->services,w,OBJID_CLIENT,CHILDID_SELF,properties[i],(LPCWSTR)s);
}
int32_t leaf_annotations_set(LeafAnnotations *a,void *window,
 const uint16_t *name,const uint16_t *help,uint32_t *mask) {
  if (!a || !window || !name || !help || !mask) return E_INVALIDARG;
  HWND w=(HWND)window;
  HRESULT hr=leaf_annotations_clear(a,window,mask);
  if (FAILED(hr)) return hr;
  // Empty names leave the stock proxy's naming algorithm intact.
  if (*name) {
    hr=setString(a,w,0,name); if(FAILED(hr))return hr; *mask|=(1u<<0);
    hr=setString(a,w,2,name); if(FAILED(hr))return hr; *mask|=(1u<<2);
  }
  hr=setString(a,w,1,help); if(FAILED(hr))return hr; *mask|=(1u<<1);
  hr=setString(a,w,3,help); if(FAILED(hr))return hr; *mask|=(1u<<3);
  NotifyWinEvent(EVENT_OBJECT_NAMECHANGE,w,OBJID_CLIENT,CHILDID_SELF);
  NotifyWinEvent(EVENT_OBJECT_DESCRIPTIONCHANGE,w,OBJID_CLIENT,CHILDID_SELF);
  NotifyWinEvent(EVENT_OBJECT_HELPCHANGE,w,OBJID_CLIENT,CHILDID_SELF);
  return S_OK;
}
