#include <jni.h>
#include <stdint.h>
#include "leaf_jni_internal.h"
extern int64_t leaf_sqlite_probe(int32_t);
JNIEXPORT jlong JNICALL Java_dev_leaf_testresources_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)self;
    if(!leaf_jni_check_owner(env))return -3;
    return (jlong)leaf_sqlite_probe((int32_t)which);
}
