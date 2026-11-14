#ifndef LEAF_LIVE_PROVIDER_H
#define LEAF_LIVE_PROVIDER_H
#include <stdint.h>
#include <stddef.h>
#ifdef LEAF_LIVE_PROVIDER_PROBES
#include <windows.h>
#include <uiautomationcore.h>
#endif
typedef struct LeafLiveContext LeafLiveContext;
typedef struct LeafLiveProvider LeafLiveProvider;
/* All owner operations require the context UI thread. Names are nonempty,
   valid UTF-16 with at most 65535 code units. Kinds: 1=status, 2=alert. */
int32_t leaf_live_context_new(LeafLiveContext **out);
int32_t leaf_live_context_close(LeafLiveContext **context);
/* Only at an ordinary owner turn, outside synchronous SendMessage/COM input.
   A re-entrant drain or close (for example from a provider callback) is
   refused with E_UNEXPECTED instead of touching the retirement queue. */
int32_t leaf_live_drain(LeafLiveContext *context);
/* Optional bounded wake-up: after a binding is retired the context posts one
   custom message (0x8000..0xBFFF) to the wake window so the owner loop drains
   at a safe turn instead of waiting for the next user input. NULL disables it.
   Posting happens in detach and is not an outbound COM call. */
int32_t leaf_live_context_set_wake(LeafLiveContext *context,void *window,uint32_t message);
int32_t leaf_live_create(LeafLiveContext *,void *window,int kind,const uint16_t *name,LeafLiveProvider **out);
int32_t leaf_live_stage(LeafLiveProvider *,int kind,const uint16_t *name);
/* accept is pointer-only: no COM, OS calls, allocation, deallocation or events. */
void leaf_live_accept(LeafLiveProvider *);
void leaf_live_discard(LeafLiveProvider *);
/* Publish the latest accepted snapshot, then notify once if it changed.
   Multiple accepts before a flush coalesce. A failed notification is reported;
   it cannot roll back already published native state. Handing the provider to
   UIA (WM_GETOBJECT or a notification) creates the same disconnect obligation;
   a provider tombstoned mid-flush stops notifying and keeps its snapshots alive
   until the flush returns. */
int32_t leaf_live_flush(LeafLiveProvider *,int *changed);
intptr_t leaf_live_get_object(LeafLiveProvider *,uintptr_t wp,intptr_t lp);
/* Detach only tombstones and enqueues the owned reference: no outbound COM.
   The caller must drain retired bindings at a safe turn. Retained clients own
   only C snapshots, never Nim objects or a recycled HWND lookup. */
int32_t leaf_live_detach(LeafLiveProvider **);
void leaf_live_counts(LeafLiveContext *,int *owned,int *objects);
#ifdef LEAF_LIVE_PROVIDER_PROBES
/* Compile-time only seam for the contract test: fakes the UIA API boundary and
   injects owner-thread re-entrancy. Normal builds never compile this. */
typedef struct LeafLiveProbeHooks {
 HRESULT (WINAPI *disconnect)(IRawElementProviderSimple *provider);
 HRESULT (WINAPI *event)(IRawElementProviderSimple *provider,EVENTID id);
 HRESULT (WINAPI *property)(IRawElementProviderSimple *provider,PROPERTYID id,VARIANT before,VARIANT after);
 BOOL (WINAPI *listening)(void);
 LRESULT (WINAPI *returnRaw)(HWND window,WPARAM wp,LPARAM lp,IRawElementProviderSimple *provider);
} LeafLiveProbeHooks;
/* NULL restores the real System32 UIAutomationCore entry points. */
void leaf_live_probe_hooks(const LeafLiveProbeHooks *hooks);
int leaf_live_probe_exposed(LeafLiveProvider *provider);
#endif
#endif
