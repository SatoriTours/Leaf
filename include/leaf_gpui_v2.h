/* ABI 2 authoritative contract. Same-process callers guarantee pointer readability. */
#ifndef LEAF_GPUI_V2_H
#define LEAF_GPUI_V2_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Optional FRAME value payload, only when config flag 1 requests frame callbacks. */
typedef struct LeafFrameSample { double elapsed_ms, draw_ms, rust_prepare_ms, rust_apply_ms; uint64_t host_renders; } LeafFrameSample;
#define LEAF_V2_ABI UINT64_C(2)
#define LEAF_V2_MAX_WIRE_BYTES UINT64_C(67108864)
#define LEAF_V2_MAX_OPS UINT64_C(40064)
#define LEAF_V2_MAX_NODES UINT64_C(10000)
#define LEAF_V2_MAX_DEPTH UINT64_C(64)
#define LEAF_V2_MAX_STRING UINT64_C(1048576)
#define LEAF_V2_MAX_TREE UINT64_C(16777216)
#define LEAF_V2_MAX_LIST UINT64_C(100000)
#define LEAF_P_WIDTH UINT64_C(1)
#define LEAF_P_HEIGHT UINT64_C(2)
#define LEAF_P_GAP UINT64_C(4)
#define LEAF_P_PADDING UINT64_C(8)
#define LEAF_P_FLEX_GROW UINT64_C(16)
#define LEAF_P_FLEX_SHRINK UINT64_C(32)
#define LEAF_P_MIN_WIDTH UINT64_C(64)
#define LEAF_P_MIN_HEIGHT UINT64_C(128)
#define LEAF_P_MAX_WIDTH UINT64_C(256)
#define LEAF_P_MAX_HEIGHT UINT64_C(512)
#define LEAF_P_RADIUS UINT64_C(1024)
#define LEAF_P_BORDER_WIDTH UINT64_C(2048)
#define LEAF_P_OPACITY UINT64_C(4096)
#define LEAF_P_FONT_SIZE UINT64_C(8192)
#define LEAF_P_PROGRESS UINT64_C(16384)
#define LEAF_P_COLOR UINT64_C(32768)
#define LEAF_P_BACKGROUND UINT64_C(65536)
#define LEAF_P_BORDER_COLOR UINT64_C(131072)
#define LEAF_P_ALIGN UINT64_C(262144)
#define LEAF_P_JUSTIFY UINT64_C(524288)
#define LEAF_P_OVERFLOW UINT64_C(1048576)
#define LEAF_P_WEIGHT UINT64_C(2097152)
#define LEAF_P_VARIANT UINT64_C(4194304)
#define LEAF_P_ENABLED UINT64_C(8388608)
#define LEAF_P_CHECKED UINT64_C(16777216)
#define LEAF_P_RESET UINT64_C(33554432)
#define LEAF_P_LIST UINT64_C(67108864)
#define LEAF_STATUS_OK UINT64_C(0)
#define LEAF_STATUS_INVALID UINT64_C(1)
#define LEAF_STATUS_INCOMPATIBLE UINT64_C(2)
#define LEAF_STATUS_STALE UINT64_C(3)
#define LEAF_STATUS_FAULTED UINT64_C(4)
#define LEAF_STATUS_REJECTED UINT64_C(5)
#define LEAF_STATUS_ACCEPTED_SCOPE_ERROR UINT64_C(6)
#define LEAF_OP_CREATE UINT64_C(1)
#define LEAF_OP_UPDATE UINT64_C(2)
#define LEAF_OP_SET_CHILDREN UINT64_C(3)
#define LEAF_OP_REMOVE UINT64_C(4)
#define LEAF_OP_BOUNDARY UINT64_C(5)
#define LEAF_OP_WINDOW UINT64_C(6)
#define LEAF_REQUEST_EVENT UINT64_C(1)
#define LEAF_REQUEST_VIEWPORT UINT64_C(2)
#define LEAF_REQUEST_STATUS UINT64_C(3)
#define LEAF_REPLY_STATUS_VALID UINT64_C(2)
#define LEAF_REQUEST_READY UINT64_C(4)
#define LEAF_REQUEST_LOCATE UINT64_C(5)
#define LEAF_REQUEST_RENDERING UINT64_C(6)
#define LEAF_REQUEST_FRAME UINT64_C(7)
/* Props.numbers: gap,padding,grow,shrink,min_w,min_h,max_w,max_h,radius,border,opacity,font_size,progress. */
/* Colors are 0xRRGGBBAA. Presence is authoritative; zero is a valid explicit value. */
typedef struct LeafBytes LeafBytes;
typedef struct LeafSpan LeafSpan;
typedef struct LeafError LeafError;
typedef struct LeafDimension LeafDimension;
typedef struct LeafProps LeafProps;
typedef struct LeafOp LeafOp;
typedef struct LeafBatch LeafBatch;
typedef struct LeafProtected LeafProtected;
typedef struct LeafRequest LeafRequest;
typedef struct LeafRow LeafRow;
typedef struct LeafReply LeafReply;
typedef struct LeafConfig LeafConfig;
typedef struct LeafRendererApi LeafRendererApi;
typedef struct LeafHostCallbacks LeafHostCallbacks;
typedef struct LeafGpuiApiV2 LeafGpuiApiV2;
typedef int32_t (*LeafPrepareFn)(void * ctx, const LeafBatch * batch, LeafError * error);
typedef int32_t (*LeafApplyFn)(void * ctx, LeafError * error);
typedef void (*LeafAcceptFn)(void * ctx, uint64_t revision);
typedef void (*LeafDiscardFn)(void * ctx);
typedef int32_t (*LeafAttachFn)(void * ctx, const LeafRendererApi * api, void * renderer_ctx, LeafError * error);
typedef int32_t (*LeafRequestFn)(void * ctx, const LeafRequest * request, LeafReply * reply, LeafError * error);
typedef void (*LeafDetachFn)(void * ctx);
typedef int32_t (*LeafRunFn)(const LeafConfig * config, const LeafHostCallbacks * callbacks, void * ctx, LeafError * error);
struct LeafBytes {
  const uint8_t * ptr;
  uint64_t len;
};
struct LeafSpan {
  uint64_t offset;
  uint64_t len;
};
struct LeafError {
  uint8_t * ptr;
  uint64_t capacity;
  uint64_t written;
};
struct LeafDimension {
  uint32_t tag;
  uint32_t reserved;
  double value;
};
struct LeafProps {
  uint64_t present;
  LeafDimension width;
  LeafDimension height;
  double numbers[13];
  uint32_t colors[3];
  uint32_t align;
  uint32_t justify;
  uint32_t overflow;
  uint32_t weight;
  uint32_t variant;
  uint32_t enabled;
  uint32_t checked;
  uint32_t event_mask;
  uint64_t reset_token;
  LeafSpan text;
  LeafSpan placeholder;
  uint64_t list_generation;
  uint64_t list_count;
  uint32_t height_mode;
  uint32_t overscan;
  double row_height;
  double estimate;
};
struct LeafOp {
  uint32_t tag;
  uint32_t kind;
  uint64_t handle;
  uint64_t parent;
  LeafSpan node_id;
  LeafProps props;
  LeafSpan children;
  uint64_t boundary_id;
  uint64_t boundary_parent;
  uint32_t width;
  uint32_t height;
};
struct LeafBatch {
  uint32_t struct_size;
  uint32_t abi;
  uint64_t session_id;
  uint64_t base_revision;
  uint64_t next_revision;
  const LeafOp * ops;
  uint64_t ops_len;
  const uint64_t * children;
  uint64_t children_len;
  const uint8_t * strings;
  uint64_t strings_len;
};
struct LeafProtected {
  uint64_t index;
  LeafBytes key;
};
struct LeafRequest {
  uint32_t struct_size;
  uint32_t tag;
  uint64_t session_id;
  uint64_t handle;
  uint64_t generation;
  uint64_t binding_generation;
  uint64_t sequence;
  uint64_t revision;
  uint32_t kind;
  uint32_t composition;
  uint32_t checked;
  uint32_t reserved;
  uint64_t first;
  uint64_t finish;
  LeafBytes value;
  const LeafProtected * protected_rows;
  uint64_t protected_len;
  double scale;
  double width;
  double height;
};
struct LeafRow {
  uint64_t handle;
  uint64_t index;
  LeafBytes key;
};
struct LeafReply {
  uint32_t struct_size;
  uint32_t status;
  uint64_t accepted_revision;
  uint64_t flags;
  const LeafRow * rows;
  uint64_t rows_len;
  double x;
  double y;
  double width;
  double height;
  /* STATUS only: flags & LEAF_REPLY_STATUS_VALID marks an owned-by-host UTF-8 value.
     Rust copies it synchronously; an empty value clears the external watch error. */
  LeafBytes value;
};
struct LeafConfig {
  uint32_t struct_size;
  uint32_t flags;
  uint64_t session_id;
  uint32_t width;
  uint32_t height;
  LeafBytes title;
};
struct LeafRendererApi {
  uint32_t struct_size;
  uint32_t abi;
  LeafPrepareFn prepare;
  LeafApplyFn apply;
  LeafAcceptFn accept;
  LeafDiscardFn discard;
};
struct LeafHostCallbacks {
  uint32_t struct_size;
  uint32_t reserved;
  LeafAttachFn attach;
  LeafRequestFn request;
  LeafDetachFn detach;
};
struct LeafGpuiApiV2 {
  uint32_t struct_size;
  uint32_t abi;
  uint64_t capabilities;
  LeafRunFn run;
};
/* Byte arrays are borrowed for the call. Host reply rows survive until the next request. */
/* accept/discard/detach never fail, unwind, allocate or call business code. */
int32_t leaf_gpui_query_v2(uint32_t abi, LeafGpuiApiV2 *out, uint64_t out_size, LeafError *error);
#ifdef __cplusplus
}
#endif
#endif
