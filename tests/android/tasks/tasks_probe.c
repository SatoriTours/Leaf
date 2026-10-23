#include <jni.h>
#include "leaf_jni_internal.h"
extern int leaf_tasks_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testtasks_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)self;
    return leaf_jni_check_owner(env) ? leaf_tasks_probe(which) : -1;
}
