// Small C ABI over the existing Windows SDK COM interfaces. No application
// callbacks, C++ compiler/runtime, containers or renderer fallback live here.
#include "canvas_bridge.h"
#define COBJMACROS
#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>
#include <stdlib.h>
#include <stdbool.h>
#include <float.h>
#include <string.h>

// Pool lifetime is exactly one prepared scene. Commands borrow geometries;
// no cross-frame registry, device cache or unbounded eviction policy exists.
typedef struct ScenePath {
  ID2D1PathGeometry *geometry;
  LeafCanvasPathSegment *segments;
  struct ScenePath *next;
  uint64_t hash;
  int32_t count, evenOdd;
} ScenePath;
static uint32_t pathBuckets(int32_t count) {
  uint32_t capacity=16;
  while(capacity<(uint32_t)count*2) capacity*=2;
  return capacity;
}
typedef struct NativeCommand {
  LeafCanvasCommandData data;
  ID2D1PathGeometry *path;
  ID2D1RoundedRectangleGeometry *rounded;
  IDWriteTextLayout *text;
  ID2D1RectangleGeometry *clip;
  ID2D1Layer *layer;
  bool initialized;
} NativeCommand;
struct LeafCanvasScene {
  LeafCanvasSurface *owner;
  LeafCanvasScene *next, *previous;
  NativeCommand *commands;
  ScenePath *paths, **pathTable;
  uint32_t pathCapacity;
  int32_t count;
  bool ready;
};
struct LeafCanvasSurface {
  HWND window;
  D2D1_RENDER_TARGET_TYPE mode;
  ID2D1Factory *factory;
  IDWriteFactory *write;
  ID2D1HwndRenderTarget *target;
  ID2D1SolidColorBrush *brush;
  LeafCanvasScene *scenes;
  int32_t width, height;
};
static volatile LONG surfaces, scenes, geometries, textLayouts, layers, brushes, targets, factories;
// C SDK inheritance is nested in some MinGW vtables. Cast to the actual base
// interface before calling inherited methods instead of guessing slot numbers
// or depending on the SDK's occasionally incorrect convenience macro arities.
#define CALL(p, method, ...) ((p)->lpVtbl->method((p), ##__VA_ARGS__))
#define RT(p) ((ID2D1RenderTarget*)(p))
#define SINK(p) ((ID2D1SimplifiedGeometrySink*)(p))
#define BRUSH(p) ((ID2D1Brush*)(p))
#define GEO(p) ((ID2D1Geometry*)(p))
#define RELEASE(p) CALL(((IUnknown*)(p)),Release)
#define DROP(p, counter) do { if(p) { RELEASE(p); (p)=0; InterlockedDecrement(&(counter)); } } while(0)
static const GUID factoryIid={0x06152247,0x6f50,0x465a,{0x92,0x45,0x11,0x8b,0xfd,0x3b,0x60,0x07}};
static const GUID writeIid={0xb859ee5a,0xd838,0x4b5b,{0xa2,0xe8,0x1a,0xdc,0x7d,0x93,0xdb,0x48}};
static D2D1_POINT_2F point(float x,float y) { return (D2D1_POINT_2F){x,y}; }
static D2D1_RECT_F rectangle(float l,float t,float r,float b) { return (D2D1_RECT_F){l,t,r,b}; }
static D2D1_MATRIX_3X2_F identity(void) { return (D2D1_MATRIX_3X2_F){1,0,0,1,0,0}; }
static D2D1_COLOR_F colorOf(const float *v) { return (D2D1_COLOR_F){v[0],v[1],v[2],v[3]}; }

static HRESULT createTarget(LeafCanvasSurface *surface) {
  D2D1_RENDER_TARGET_PROPERTIES props={0}; props.type=surface->mode;
  D2D1_HWND_RENDER_TARGET_PROPERTIES window={0};
  window.hwnd=surface->window; window.pixelSize.width=surface->width; window.pixelSize.height=surface->height;
  HRESULT status=CALL(surface->factory,CreateHwndRenderTarget,&props,&window,&surface->target);
  if(surface->target) InterlockedIncrement(&targets);
  if(FAILED(status)) return status;
  D2D1_COLOR_F black={0,0,0,1};
  status=CALL(RT(surface->target),CreateSolidColorBrush,&black,NULL,&surface->brush);
  if(surface->brush) InterlockedIncrement(&brushes);
  return status;
}
int32_t leaf_canvas_new(void *window,int32_t software,LeafCanvasSurface **output) {
  if(!output) return E_POINTER;
  *output=NULL;
  if(!window || !IsWindow((HWND)window)) return E_INVALIDARG;
  LeafCanvasSurface *surface=calloc(1,sizeof(LeafCanvasSurface));
  if(!surface) return E_OUTOFMEMORY;
  InterlockedIncrement(&surfaces);
  surface->window=(HWND)window;
  surface->mode=software?D2D1_RENDER_TARGET_TYPE_SOFTWARE:D2D1_RENDER_TARGET_TYPE_HARDWARE;
  surface->width=surface->height=1; // Hidden, private preparation surface.
  HRESULT status=D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,&factoryIid,NULL,(void**)&surface->factory);
  if(surface->factory) InterlockedIncrement(&factories);
  if(SUCCEEDED(status)) {
    status=DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,&writeIid,(IUnknown**)&surface->write);
    if(surface->write) InterlockedIncrement(&factories);
  }
  if(SUCCEEDED(status)) status=createTarget(surface);
  if(FAILED(status)) { leaf_canvas_release(surface); return status; }
  *output=surface; return S_OK;
}
void leaf_canvas_scene_release(LeafCanvasScene *scene) {
  if(!scene) return;
  for(int32_t i=0;i<scene->count;++i) {
    NativeCommand *command=&scene->commands[i];
    DROP(command->rounded,geometries); DROP(command->text,textLayouts);
    DROP(command->clip,geometries); DROP(command->layer,layers);
  }
  if(scene->previous) scene->previous->next=scene->next;
  else scene->owner->scenes=scene->next;
  if(scene->next) scene->next->previous=scene->previous;
  while(scene->paths) {
    ScenePath *entry=scene->paths;scene->paths=entry->next;
    DROP(entry->geometry,geometries);free(entry->segments);free(entry);
  }
  free(scene->pathTable);
  free(scene->commands); free(scene); InterlockedDecrement(&scenes);
}
void leaf_canvas_release(LeafCanvasSurface *surface) {
  if(!surface) return;
  while(surface->scenes) leaf_canvas_scene_release(surface->scenes);
  DROP(surface->brush,brushes); DROP(surface->target,targets);
  DROP(surface->write,factories); DROP(surface->factory,factories);
  free(surface); InterlockedDecrement(&surfaces);
}
uint64_t leaf_canvas_scene_bytes(int32_t count) {
  if(count<0 || count>100000) return UINT64_MAX;
  // Conservative bound: one unique pool entry per command and a <=50% full
  // table. Native segment-key bytes are charged separately by the Nim owner.
  return sizeof(LeafCanvasScene)+(uint64_t)count*(sizeof(NativeCommand)+sizeof(ScenePath))+
    (uint64_t)pathBuckets(count)*sizeof(ScenePath*);
}
int32_t leaf_canvas_scene_new(LeafCanvasSurface *surface,int32_t count,LeafCanvasScene **output) {
  if(!surface || !output || count<0 || count>100000) return E_INVALIDARG;
  *output=NULL;
  LeafCanvasScene *scene=calloc(1,sizeof(LeafCanvasScene));
  if(!scene) return E_OUTOFMEMORY;
  if(count) {
    scene->commands=calloc(count,sizeof(NativeCommand));
    if(!scene->commands) { free(scene); return E_OUTOFMEMORY; }
  }
  scene->count=count;scene->owner=surface;scene->next=surface->scenes;
  if(scene->next) scene->next->previous=scene;
  surface->scenes=scene; InterlockedIncrement(&scenes); *output=scene;
  return S_OK;
}
int32_t leaf_canvas_scene_set(LeafCanvasScene *scene,int32_t index,const LeafCanvasCommandData *data) {
  if(!scene || !data || index<0 || index>=scene->count || data->kind<0 || data->kind>6 || scene->ready) return E_INVALIDARG;
  NativeCommand *command=&scene->commands[index];
  if(command->initialized) return E_UNEXPECTED;
  command->data=*data;command->initialized=true;
  if(data->kind==0 && (data->flags&8)) {
    D2D1_ROUNDED_RECT box={rectangle(data->values[0],data->values[1],
      data->values[0]+data->values[2],data->values[1]+data->values[3]),data->values[4],data->values[4]};
    HRESULT status=CALL(scene->owner->factory,CreateRoundedRectangleGeometry,&box,&command->rounded);
    if(command->rounded) InterlockedIncrement(&geometries);
    if(FAILED(status)) return status;
  }
  if(data->kind==5 && (data->flags&4)) {
    D2D1_RECT_F box=rectangle(data->values[0],data->values[1],data->values[0]+data->values[2],data->values[1]+data->values[3]);
    HRESULT status=CALL(scene->owner->factory,CreateRectangleGeometry,&box,&command->clip);
    if(command->clip) InterlockedIncrement(&geometries);
    if(FAILED(status)) return status;
    status=CALL(RT(scene->owner->target),CreateLayer,NULL,&command->layer);
    if(command->layer) InterlockedIncrement(&layers);
    return status;
  }
  return S_OK;
}
int32_t leaf_canvas_scene_path(LeafCanvasScene *scene,int32_t index,const LeafCanvasPathSegment *data,int32_t count,int32_t evenOdd) {
  if(!scene || index<0 || index>=scene->count || !data || count<=0 || count>250000 || scene->ready) return E_INVALIDARG;
  NativeCommand *command=&scene->commands[index];
  if(!command->initialized || command->data.kind!=3 || command->path) return E_UNEXPECTED;
  if(!scene->pathTable) {
    scene->pathCapacity=pathBuckets(scene->count);
    scene->pathTable=calloc(scene->pathCapacity,sizeof(ScenePath*));
    if(!scene->pathTable) return E_OUTOFMEMORY;
  }
  const size_t bytes=(size_t)count*sizeof(*data);
  uint64_t hash=14695981039346656037ULL;
  const unsigned char *raw=(const unsigned char*)data;
  for(size_t i=0;i<bytes;++i) { hash^=raw[i];hash*=1099511628211ULL; }
  hash^=(uint32_t)count;hash*=1099511628211ULL;
  hash^=(evenOdd!=0);hash*=1099511628211ULL;
  uint32_t slot=(uint32_t)hash&(scene->pathCapacity-1);
  bool insert=false;
  // Bound collision work, even for adversarial sealed input. A full probe
  // chain simply creates a non-interned entry with identical drawing semantics.
  for(int probe=0;probe<8;++probe) {
    ScenePath *found=scene->pathTable[slot];
    if(!found) { insert=true;break; }
    if(found->hash==hash && found->count==count && found->evenOdd==(evenOdd!=0) &&
        memcmp(found->segments,data,bytes)==0) {
      command->path=found->geometry;return S_OK;
    }
    slot=(slot+1)&(scene->pathCapacity-1);
  }
  ScenePath *entry=calloc(1,sizeof(ScenePath));
  if(!entry) return E_OUTOFMEMORY;
  entry->segments=malloc(bytes);
  if(!entry->segments) { free(entry);return E_OUTOFMEMORY; }
  memcpy(entry->segments,data,bytes);entry->count=count;entry->evenOdd=(evenOdd!=0);entry->hash=hash;
  entry->next=scene->paths;scene->paths=entry;
  HRESULT status=CALL(scene->owner->factory,CreatePathGeometry,&entry->geometry);
  command->path=entry->geometry;
  if(entry->geometry) InterlockedIncrement(&geometries);
  if(FAILED(status)) return status;
  ID2D1GeometrySink *sink=NULL;
  status=CALL(command->path,Open,&sink);
  if(FAILED(status)) { if(sink) RELEASE(sink); return status; }
  CALL(SINK(sink),SetFillMode,evenOdd?D2D1_FILL_MODE_ALTERNATE:D2D1_FILL_MODE_WINDING);
  bool open=false;
  for(int32_t i=0;i<count;++i) {
    const LeafCanvasPathSegment *segment=&data[i];
    switch(segment->kind) {
      case 0:
        if(open) CALL(SINK(sink),EndFigure,D2D1_FIGURE_END_OPEN);
        CALL(SINK(sink),BeginFigure,point(segment->points[0],segment->points[1]),D2D1_FIGURE_BEGIN_FILLED);
        open=true;break;
      case 1:
        if(!open) { status=E_INVALIDARG;break; }
        CALL(sink,AddLine,point(segment->points[0],segment->points[1]));break;
      case 2: {
        if(!open) { status=E_INVALIDARG;break; }
        D2D1_BEZIER_SEGMENT curve={point(segment->points[0],segment->points[1]),point(segment->points[2],segment->points[3]),point(segment->points[4],segment->points[5])};
        CALL(sink,AddBezier,&curve);break;
      }
      case 3:
        if(!open) { status=E_INVALIDARG;break; }
        CALL(SINK(sink),EndFigure,D2D1_FIGURE_END_CLOSED);open=false;break;
      default:status=E_INVALIDARG;
    }
    if(FAILED(status)) break;
  }
  if(open) CALL(SINK(sink),EndFigure,D2D1_FIGURE_END_OPEN);
  const HRESULT closed=CALL(SINK(sink),Close); RELEASE(sink);
  status=FAILED(status)?status:closed;
  if(SUCCEEDED(status) && insert) scene->pathTable[slot]=entry;
  return status;
}
int32_t leaf_canvas_scene_text(LeafCanvasScene *scene,int32_t index,const uint16_t *text,int32_t count,const uint16_t *font,float size) {
  if(!scene || index<0 || index>=scene->count || !text || !font || count<0 || size<=0 || scene->ready) return E_INVALIDARG;
  NativeCommand *command=&scene->commands[index];
  if(!command->initialized || command->data.kind!=4 || command->text) return E_UNEXPECTED;
  IDWriteTextFormat *format=NULL;
  HRESULT status=CALL(scene->owner->write,CreateTextFormat,(const WCHAR*)font,NULL,DWRITE_FONT_WEIGHT_NORMAL,
    DWRITE_FONT_STYLE_NORMAL,DWRITE_FONT_STRETCH_NORMAL,size,L"en-US",&format);
  if(FAILED(status)) { if(format) RELEASE(format);return status; }
  status=CALL(format,SetWordWrapping,DWRITE_WORD_WRAPPING_NO_WRAP);
  if(SUCCEEDED(status)) status=CALL(scene->owner->write,CreateTextLayout,(const WCHAR*)text,count,format,16384.f,16384.f,&command->text);
  if(command->text) InterlockedIncrement(&textLayouts);
  RELEASE(format);return status;
}
int32_t leaf_canvas_scene_ready(LeafCanvasScene *scene) {
  if(!scene || scene->ready) return E_INVALIDARG;
  int depth=0;
  for(int i=0;i<scene->count;++i) {
    NativeCommand *command=&scene->commands[i];
    if(!command->initialized || (command->data.kind==3 && !command->path) || (command->data.kind==4 && !command->text)) return E_INVALIDARG;
    if(command->data.kind==5) { if(++depth>64) return E_INVALIDARG; }
    if(command->data.kind==6) { if(--depth<0) return E_INVALIDARG; }
  }
  if(depth) return E_INVALIDARG;
  scene->ready=true;return S_OK;
}
// Complex containment is queried against the very same prepared SDK resources
// used for painting. Ordinary shapes stay on the shared exact geometry path.
int32_t leaf_canvas_scene_contains(LeafCanvasScene *scene,int32_t index,float x,float y,int32_t *inside) {
  if(!inside) return E_POINTER;
  *inside=0;
  if(!scene || !scene->ready || index<0 || index>=scene->count) return E_INVALIDARG;
  NativeCommand *command=&scene->commands[index];
  if(command->data.kind==4) {
    if(!command->text || !(command->data.flags&1) || command->data.fill[3]<=0) return S_OK;
    BOOL trailing=FALSE, inLayout=FALSE;
    DWRITE_HIT_TEST_METRICS metrics={0};
    HRESULT status=CALL(command->text,HitTestPoint,x-command->data.values[0],y-command->data.values[1],
      &trailing,&inLayout,&metrics);
    if(SUCCEEDED(status)) *inside=inLayout && metrics.isText && metrics.length>0;
    return status;
  }
  ID2D1Geometry *geometry=NULL;
  if(command->data.kind==3 && command->path) geometry=GEO(command->path);
  else if(command->data.kind==0 && command->rounded) geometry=GEO(command->rounded);
  else return E_INVALIDARG;
  BOOL contains=FALSE;
  HRESULT status=S_OK;
  if((command->data.flags&1) && command->data.fill[3]>0) {
    status=CALL(geometry,FillContainsPoint,point(x,y),NULL,0.25f,&contains);
    if(FAILED(status)) return status;
    if(contains) { *inside=1;return S_OK; }
  }
  if((command->data.flags&2) && command->data.stroke[3]>0 && command->data.strokeWidth>0) {
    status=CALL(geometry,StrokeContainsPoint,point(x,y),command->data.strokeWidth,NULL,NULL,0.25f,&contains);
    if(SUCCEEDED(status)) *inside=contains;
  }
  return status;
}
static D2D1_MATRIX_3X2_F matrixOf(const float *v) { return (D2D1_MATRIX_3X2_F){v[0],v[1],v[2],v[3],v[4],v[5]}; }
static D2D1_MATRIX_3X2_F multiply(const D2D1_MATRIX_3X2_F *a,const D2D1_MATRIX_3X2_F *b) {
  return (D2D1_MATRIX_3X2_F){a->_11*b->_11+a->_12*b->_21,a->_11*b->_12+a->_12*b->_22,
    a->_21*b->_11+a->_22*b->_21,a->_21*b->_12+a->_22*b->_22,
    a->_31*b->_11+a->_32*b->_21+b->_31,a->_31*b->_12+a->_32*b->_22+b->_32};
}
int32_t leaf_canvas_draw(LeafCanvasSurface *surface,LeafCanvasScene *scene,int32_t width,int32_t height,float dpi,
    const float *matrix,const float *background,float designWidth,float designHeight) {
  if(!surface || !scene || scene->owner!=surface || !scene->ready || !surface->target || !surface->brush ||
      width<=0 || height<=0 || width>16384 || height>16384 || (int64_t)width*height>32000000 || dpi<=0 || !matrix || !background) return E_INVALIDARG;
  if(width!=surface->width || height!=surface->height) {
    D2D1_SIZE_U size={width,height};
    const HRESULT resized=CALL(surface->target,Resize,&size);
    if(FAILED(resized)) return resized;
    surface->width=width;surface->height=height;
  }
  ID2D1RenderTarget *target=RT(surface->target);
  D2D1_MATRIX_3X2_F unit=identity(),current=matrixOf(matrix),saved[64];
  D2D1_COLOR_F clear=colorOf(background);bool clipped[64];int depth=0;
  CALL(target,SetDpi,dpi,dpi);CALL(target,BeginDraw);CALL(target,SetTransform,&unit);CALL(target,Clear,&clear);
  CALL(target,SetTransform,&current);
  const bool designClip=designWidth>0 && designHeight>0;
  if(designClip) { D2D1_RECT_F box=rectangle(0,0,designWidth,designHeight);CALL(target,PushAxisAlignedClip,&box,D2D1_ANTIALIAS_MODE_PER_PRIMITIVE); }
  for(int i=0;i<scene->count;++i) {
    NativeCommand *command=&scene->commands[i];const LeafCanvasCommandData *data=&command->data;
    if(data->kind==5) {
      saved[depth]=current;clipped[depth]=command->layer!=NULL;++depth;
      D2D1_MATRIX_3X2_F local=matrixOf(data->matrix);current=multiply(&local,&current);CALL(target,SetTransform,&current);
      if(command->layer) {
        D2D1_LAYER_PARAMETERS layer={rectangle(-FLT_MAX,-FLT_MAX,FLT_MAX,FLT_MAX),GEO(command->clip),D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,unit,1.f,NULL,D2D1_LAYER_OPTIONS_NONE};
        CALL(target,PushLayer,&layer,command->layer);
      }
      continue;
    }
    if(data->kind==6) {
      --depth;if(clipped[depth]) CALL(target,PopLayer);current=saved[depth];CALL(target,SetTransform,&current);continue;
    }
    for(int stroke=0;stroke<2;++stroke) {
      if(!(data->flags&(stroke?2:1)) || (stroke && data->strokeWidth==0)) continue;
      D2D1_COLOR_F color=colorOf(stroke?data->stroke:data->fill);CALL(surface->brush,SetColor,&color);
      ID2D1Brush *brush=BRUSH(surface->brush);
      switch(data->kind) {
        case 0: {
          D2D1_ROUNDED_RECT box={rectangle(data->values[0],data->values[1],data->values[0]+data->values[2],data->values[1]+data->values[3]),data->values[4],data->values[4]};
          if(stroke) CALL(target,DrawRoundedRectangle,&box,brush,data->strokeWidth,NULL);
          else CALL(target,FillRoundedRectangle,&box,brush);break;
        }
        case 1: {
          D2D1_ELLIPSE circle={point(data->values[0],data->values[1]),data->values[2],data->values[2]};
          if(stroke) CALL(target,DrawEllipse,&circle,brush,data->strokeWidth,NULL);
          else CALL(target,FillEllipse,&circle,brush);break;
        }
        case 2:CALL(target,DrawLine,point(data->values[0],data->values[1]),point(data->values[2],data->values[3]),brush,data->strokeWidth,NULL);break;
        case 3:
          if(stroke) CALL(target,DrawGeometry,GEO(command->path),brush,data->strokeWidth,NULL);
          else CALL(target,FillGeometry,GEO(command->path),brush,NULL);break;
        case 4:if(!stroke) CALL(target,DrawTextLayout,point(data->values[0],data->values[1]),command->text,brush,D2D1_DRAW_TEXT_OPTIONS_NONE);break;
      }
    }
  }
  if(designClip) CALL(target,PopAxisAlignedClip);
  return CALL(target,EndDraw,NULL,NULL);
}
int32_t leaf_canvas_rebuild(LeafCanvasSurface *surface) {
  if(!surface || !IsWindow(surface->window)) return E_INVALIDARG;
  for(LeafCanvasScene *scene=surface->scenes;scene;scene=scene->next)
    for(int i=0;i<scene->count;++i) { NativeCommand *command=&scene->commands[i];DROP(command->layer,layers); }
  DROP(surface->brush,brushes);DROP(surface->target,targets);
  HRESULT status=createTarget(surface);
  if(FAILED(status)) return status;
  for(LeafCanvasScene *scene=surface->scenes;scene;scene=scene->next)
    for(int i=0;i<scene->count;++i) {
      NativeCommand *command=&scene->commands[i];
      if(command->clip) {
        status=CALL(RT(surface->target),CreateLayer,NULL,&command->layer);
        if(command->layer) InterlockedIncrement(&layers);
        if(FAILED(status)) return status;
      }
    }
  return S_OK;
}
void leaf_canvas_validate_paint(LeafCanvasSurface *surface) {
  if(!surface || !IsWindow(surface->window)) return;
  PAINTSTRUCT paint;BeginPaint(surface->window,&paint);EndPaint(surface->window,&paint);
}
void leaf_canvas_counts(LeafCanvasCounts *output) {
  if(!output) return;
  output->surfaces=surfaces;output->scenes=scenes;output->geometries=geometries;output->textLayouts=textLayouts;
  output->layers=layers;output->brushes=brushes;output->targets=targets;output->factories=factories;
}
