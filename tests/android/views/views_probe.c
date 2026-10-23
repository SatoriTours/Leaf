#include <jni.h>
#include <stdint.h>
#include "leaf_jni_internal.h"
extern int leaf_views_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testviews_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)self;
    return leaf_jni_check_owner(env) ? leaf_views_probe(which) : -1;
}
