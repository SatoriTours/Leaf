/* Dedicated UI Automation provider for the standard single select.
 *
 * Declares exactly what select_provider.c exposes to the Win32 backend. See
 * select_uia.h for the interface identity/ABI provenance and docs/ui/README.md
 * for the supported/unsupported semantics.
 */
#ifndef LEAF_SELECT_PROVIDER_H
#define LEAF_SELECT_PROVIDER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct LeafSelectContext LeafSelectContext;
typedef struct LeafProvider LeafProvider;

typedef struct LeafSelectItem {
  int32_t disabled;
  int32_t length;          /* UTF-16 code units, no terminator */
  const uint16_t *label;
} LeafSelectItem;

/* Request kinds recorded by provider callbacks for the owner turn. */
enum {
  LEAF_SELECT_REQUEST_NONE = 0,
  LEAF_SELECT_REQUEST_EXPAND = 1,
  LEAF_SELECT_REQUEST_COLLAPSE = 2,
  LEAF_SELECT_REQUEST_SELECT = 3,
  LEAF_SELECT_REQUEST_FOCUS = 4
};

int32_t leaf_select_context_new(LeafSelectContext **out);
int32_t leaf_select_context_set_wake(LeafSelectContext *c, void *window,
                                     uint32_t message);
int32_t leaf_select_context_close(LeafSelectContext **slot);

/* trigger = ComboBox fragment root; popup = List fragment root. */
int32_t leaf_select_trigger_new(LeafSelectContext *c, void *window,
                                LeafProvider **out);
int32_t leaf_select_popup_new(LeafSelectContext *c, void *window,
                              LeafProvider **out);
/* Cross-links for navigation (trigger child <-> popup parent). */
int32_t leaf_select_link(LeafProvider *trigger, LeafProvider *popup);

/* A complete snapshot: accepted open/value state plus the candidate rows. */
int32_t leaf_select_stage(LeafProvider *p, int32_t open, int32_t enabled,
                          const uint16_t *name, const uint16_t *value,
                          const LeafSelectItem *items, int32_t count,
                          int32_t selectedIndex, int32_t focused, int32_t visible,
                          int32_t firstRow, int32_t rows, int32_t rowHeightPx);
void leaf_select_accept(LeafProvider *p);
void leaf_select_discard(LeafProvider *p);
/* Publishes the accepted snapshot and raises the necessary events. */
int32_t leaf_select_publish(LeafProvider *p, int32_t *changed);
intptr_t leaf_select_get_object(LeafProvider *p, uintptr_t wparam,
                                intptr_t lparam);
int32_t leaf_select_detach(LeafProvider **slot);
int32_t leaf_select_drain(LeafSelectContext *c);
void leaf_select_counts(LeafSelectContext *c, int32_t *owned, int32_t *objects);
/* Owner turn: one bounded request recorded by a provider callback. */
/* Takes the pending request only when it came from window1 or window2. */
int32_t leaf_select_take_request(LeafSelectContext *c, void *window1, void *window2,
                                 int32_t *kind, int32_t *index, int32_t *generation,
                                 void **window);
void leaf_select_clear_request(LeafSelectContext *c);
/* Owner thread: collect retired snapshots when no reader is inside. */
int32_t leaf_select_reclaim(LeafProvider *p);
int32_t leaf_select_generation(LeafProvider *p);
/* Debug-only trace of one WM_GETOBJECT seen by the trigger subclass. */
void leaf_select_trace_w(const char *tag, void *window, intptr_t lparam, uintptr_t wparam);
int32_t leaf_select_window_live(LeafProvider *p);

#ifdef LEAF_SELECT_PROVIDER_PROBES
/* Probe-only seam (compiled with -d:leafProtocolProbes): pauses a real reader
   inside its read guard so a controlled concurrency test can publish while the
   reader holds the old snapshot. It never changes the read/free algorithm. */
int32_t leaf_select_probe_arm(LeafProvider *p);
int32_t leaf_select_probe_wait_entered(LeafProvider *p, int32_t timeoutMs);
void leaf_select_probe_release(LeafProvider *p);
int32_t leaf_select_probe_measure_value(LeafProvider *p);
int32_t leaf_select_probe_navigate_child(LeafProvider *p);
int32_t leaf_select_probe_set_value(LeafProvider *p);
int32_t leaf_select_probe_arm_exit(LeafProvider *p);
int32_t leaf_select_probe_arm_peer(LeafProvider *p);
int32_t leaf_select_probe_wait_peer(LeafProvider *p, int32_t timeoutMs);
void leaf_select_probe_release_peer(LeafProvider *p);
int32_t leaf_select_probe_peer_freed(LeafProvider *p);
int64_t leaf_select_probe_identity(LeafProvider *p);
int32_t leaf_select_probe_freed_providers(void);
int32_t leaf_select_probe_arm_drain(LeafProvider *p);
int32_t leaf_select_probe_wait_drain(LeafProvider *p, int32_t timeoutMs);
void leaf_select_probe_release_drain(LeafProvider *p);
int32_t leaf_select_probe_wait_exit(LeafProvider *p, int32_t timeoutMs);
void leaf_select_probe_release_exit(LeafProvider *p);
void leaf_select_probe_counts(int32_t *live, int32_t *allocated, int32_t *freed,
                              int32_t *readers, LeafProvider *p);
#endif

#ifdef __cplusplus
}
#endif
#endif
