#include <jni.h>
extern int leaf_protection_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testprotection_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)env;(void)self;return leaf_protection_probe(which);
}
