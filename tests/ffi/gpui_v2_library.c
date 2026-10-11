#include "../../include/leaf_gpui_v2.h"
#include <string.h>
uint32_t leaf_gpui_abi_version(void) {return 1;}
int leaf_gpui_run(const uint8_t*d,size_t n,void*c,void*ctx) {(void)d;(void)n;(void)c;(void)ctx;return 0;}
#ifndef OLD_ONLY
static int32_t prepare(void*ctx,const LeafBatch*b,LeafError*e) {(void)ctx;(void)e;return b && b->abi==2 ? 0:1;}
static int32_t apply(void*ctx,LeafError*e) {(void)ctx;(void)e;return 0;}
static void accept(void*ctx,uint64_t r) {(void)ctx;(void)r;}
static void discard(void*ctx) {(void)ctx;}
typedef int32_t (*LeafTestScript)(const LeafConfig*,const LeafHostCallbacks*,void*,LeafError*);
static LeafTestScript script;
void leaf_test_set_script(LeafTestScript value) {script=value;}
static int32_t run(const LeafConfig*c,const LeafHostCallbacks*h,void*ctx,LeafError*e) {
  LeafRendererApi api={sizeof(api),2,prepare,apply,accept,discard};
  int32_t status=h->attach(ctx,&api,NULL,e);
  if (status==0 && script) status=script(c,h,ctx,e);
  if (status==0) {
    LeafRequest req={0};req.struct_size=sizeof(req);req.tag=LEAF_REQUEST_READY;req.session_id=c->session_id;
    LeafReply reply={0};reply.struct_size=sizeof(reply);status=h->request(ctx,&req,&reply,e);
  }
  h->detach(ctx);return status;
}
int32_t leaf_gpui_query_v2(uint32_t abi,LeafGpuiApiV2*out,uint64_t n,LeafError*e) {
  (void)e;
#ifdef INCOMPATIBLE
  (void)abi;(void)out;(void)n;return LEAF_STATUS_INCOMPATIBLE;
#else
  if(abi!=2 || !out || n<sizeof(*out))return LEAF_STATUS_INCOMPATIBLE;
  LeafGpuiApiV2 api={sizeof(api),2,0,run};memcpy(out,&api,sizeof(api));return 0;
#endif
}
#endif
