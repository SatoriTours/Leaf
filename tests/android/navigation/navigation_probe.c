#include <jni.h>
extern int leaf_navigation_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testnavigation_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)env;(void)self;return leaf_navigation_probe(which);
}
