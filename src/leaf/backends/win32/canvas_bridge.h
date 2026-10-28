#ifndef LEAF_CANVAS_BRIDGE_H
#define LEAF_CANVAS_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct LeafCanvasSurface LeafCanvasSurface;
typedef struct LeafCanvasScene LeafCanvasScene;
typedef struct LeafCanvasCommandData {
  int32_t kind, flags;
  float values[8], fill[4], stroke[4], strokeWidth, matrix[6];
} LeafCanvasCommandData;
typedef struct LeafCanvasPathSegment { int32_t kind; float points[6]; } LeafCanvasPathSegment;
typedef struct LeafCanvasCounts {
  int32_t surfaces, scenes, geometries, textLayouts, layers, brushes, targets, factories;
} LeafCanvasCounts;
int32_t leaf_canvas_new(void *window, int32_t software, LeafCanvasSurface **output);
void leaf_canvas_release(LeafCanvasSurface *surface);
uint64_t leaf_canvas_scene_bytes(int32_t commands);
int32_t leaf_canvas_scene_new(LeafCanvasSurface *surface, int32_t commands, LeafCanvasScene **output);
void leaf_canvas_scene_release(LeafCanvasScene *scene);
int32_t leaf_canvas_scene_set(LeafCanvasScene *scene, int32_t index, const LeafCanvasCommandData *data);
int32_t leaf_canvas_scene_path(LeafCanvasScene *scene, int32_t index, const LeafCanvasPathSegment *segments, int32_t count, int32_t evenOdd);
int32_t leaf_canvas_scene_text(LeafCanvasScene *scene, int32_t index, const uint16_t *text, int32_t count, const uint16_t *font, float size);
int32_t leaf_canvas_scene_ready(LeafCanvasScene *scene);
int32_t leaf_canvas_scene_contains(LeafCanvasScene *scene, int32_t index, float x, float y, int32_t *inside);
int32_t leaf_canvas_draw(LeafCanvasSurface *surface, LeafCanvasScene *scene, int32_t width, int32_t height, float dpi,
  const float *matrix, const float *background, float designWidth, float designHeight);
int32_t leaf_canvas_rebuild(LeafCanvasSurface *surface);
void leaf_canvas_validate_paint(LeafCanvasSurface *surface);
void leaf_canvas_counts(LeafCanvasCounts *output);
#ifdef __cplusplus
}
#endif
#endif
