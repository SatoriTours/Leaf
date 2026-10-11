#include "../../include/leaf_gpui_v2.h"
int32_t leaf_test_prepare_call(const LeafRendererApi *api, void *ctx) {
    return api->prepare(ctx, NULL, NULL);
}
