#ifndef LEAF_ACCESSIBILITY_BRIDGE_H
#define LEAF_ACCESSIBILITY_BRIDGE_H
#include <stdint.h>
typedef struct LeafAnnotations LeafAnnotations;
int32_t leaf_annotations_new(LeafAnnotations **output);
void leaf_annotations_release(LeafAnnotations *annotations);
int32_t leaf_annotations_clear(LeafAnnotations *annotations, void *window, uint32_t *mask);
int32_t leaf_annotations_set(LeafAnnotations *annotations, void *window,
  const uint16_t *name, const uint16_t *help,
  uint32_t *mask);
#endif
