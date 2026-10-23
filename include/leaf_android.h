#ifndef LEAF_ANDROID_H
#define LEAF_ANDROID_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Internal synchronous Views ABI: version 1 basic controls, version 2 adds
 * controlled input/reset, version 3 adds remaining basic controls/checked facts,
 * version 4 adds typed virtual lists and scroll facts,
 * version 5 adds typed navigation and begin/cancel/confirm back facts.
 * Borrowed payloads expire when
 * command returns. All calls require the Nim initialization UI thread.
 * command tags: 1 measure, 2 stage, 3 apply, 4 discard, 5 replay, 6 rebind,
 * 7 dispose, 8 editor effects, 9 resume editor facts, 10 pause editor facts,
 * 11 query current UTF16 selection (two doubles; no business callback),
 * 12 replay accepted geometry using the existing Views (no creates/writes).
 * LAV1 (basic) / LAV2 (input) / LAV3 (checked/progress) / LAV4 (lists) / LAV5 (navigation) are payloads
 * documented by wire.nim and LeafView.kt; the callback structure is unchanged.
 * A command must report Java exceptions as failure, clearing them temporarily
 * to permit accepted replay; the enclosing JNI call restores the primary one. */
typedef int32_t (*LeafAndroidCommand)(void *,uint32_t,const uint8_t *,size_t,
                                    double,double,double *);
typedef struct LeafAndroidCallbacks {
    uint32_t abi_version, struct_size;
    void *context;
    LeafAndroidCommand command;
} LeafAndroidCallbacks;
/* output slots must be zero. create failure may return a nonzero cleanup owner;
 * preserve it and call close explicitly. Never serialize these process IDs.
 * create owns no View; attach transfers the platform's new view context to
 * either a Session or a retained cleanup owner, including a failed attempt. */
int32_t leaf_android_create(const LeafAndroidCallbacks *,uint64_t *owner);
/* Optional host-resource ABI v1, independent of the Views payload version.
 * Paths are borrowed strict UTF-8, copied by create; directory roots must exist.
 * read_asset is synchronous on the owning thread: first (NULL,0) queries length,
 * then a caller-owned buffer receives exactly that many binary bytes. Set the
 * zero length slot on success; never retain path/output pointers. No exception
 * crosses C. The context remains alive until successful close, including a
 * nonzero cleanup owner returned by failed creation. */
typedef int32_t (*LeafAndroidReadAsset)(void *,const uint8_t *,size_t,
                                      uint8_t *,size_t,size_t *);
typedef struct LeafAndroidResources {
    uint32_t abi_version, struct_size;
    void *context;
    LeafAndroidReadAsset read_asset;
    const uint8_t *data_directory;
    size_t data_length;
    const uint8_t *cache_directory;
    size_t cache_length;
} LeafAndroidResources;
int32_t leaf_android_create_with_resources(const LeafAndroidCallbacks *,
                                          const LeafAndroidResources *,uint64_t *owner);

int32_t leaf_android_attach(uint64_t,double,double,double,uint64_t *mount);
/* phases 1 resume, 2 pause, 3 turn, 4 detach; rejected/stale = 5, failure = 6 */
int32_t leaf_android_phase(uint64_t,uint64_t,uint32_t);
int32_t leaf_android_event(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                          uint64_t,uint64_t,uint64_t,uint32_t);
/* Same eight identity fields as event. kind=1 change/2 submit, phase=0..4,
 * selection is nonnegative UTF-16 code units. Borrowed strict scalar UTF-8,
 * max 1 MiB, NULL iff empty; never retained. Foreign/paused/stale facts do not
 * mutate editor metadata. Reset advances the per-control binding generation. */
int32_t leaf_android_input(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                          uint64_t,uint64_t,uint64_t,uint32_t,
                          const uint8_t *,size_t,uint32_t,int32_t,int32_t);
/* ABI3 checkbox/toggle fact; same eight identity fields, checked must be 0/1.
 * No composition/selection/text facts apply to these controls. */
int32_t leaf_android_checked(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                            uint64_t,uint64_t,uint64_t,uint32_t);
/* ABI4: owner/activity/session/event-mount/list/sequence/revision/source.
 * A finite desired DIP offset only records an intent. No row builder or native
 * layout runs here. Accepted per-list sequences must increase in this mount. */
int32_t leaf_android_scroll(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                           uint64_t,uint64_t,uint64_t,double);
/* ABI4 row protection: owner/activity/session/event-mount/control/sequence/
 * revision/binding. Complete mask: bit 0 focused, bit 1 composing (input only),
 * zero releases; other bits are rejected. Records facts and replaces queued
 * row requests before the next ordinary turn; runs no business/native layout.
 * Foreign, paused, removed or stale controls cannot pin replacement rows. */
int32_t leaf_android_protect(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                            uint64_t,uint64_t,uint64_t,uint32_t);
/* ABI5: borrowed fixed-width fact, copied before return. phase=0 begin,
 * 1 cancel, 2 confirm. Success queues a fact; only an ordinary resumed turn
 * may commit business history. Root back remains the platform host's action.
 * Identity fields describe the accepted container, never a native history. */
typedef struct LeafAndroidBackFact {
    uint64_t session, mount, handle, binding, sequence, revision, request;
    uint64_t router, history, current, previous;
    uint32_t depth, phase;
} LeafAndroidBackFact;
int32_t leaf_android_back(uint64_t,uint64_t,const LeafAndroidBackFact *);
int32_t leaf_android_close(uint64_t);
#ifdef __cplusplus
}
#endif
#endif
