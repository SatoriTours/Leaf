#include <jni.h>
#include "leaf_jni_internal.h"
extern int leaf_controls_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testcontrols_MainActivity_marker(JNIEnv *env,jobject self,jint n) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return -1;
    return leaf_controls_probe(n);
}
