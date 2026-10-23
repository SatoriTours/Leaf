#include <jni.h>
extern int leaf_lists_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testlists_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)env;(void)self;return leaf_lists_probe(which);
}
