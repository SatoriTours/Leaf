#include <jni.h>
#include <unistd.h>
extern int leaf_boundary_marker(int thread_id);

/* Test-only JNI entry. Called exclusively after product main-thread init. */
JNIEXPORT jint JNICALL Java_dev_leaf_testbridge_MainActivity_initializationMarker(
        JNIEnv *env, jobject activity) {
    (void)env;
    (void)activity;
    return leaf_boundary_marker(gettid());
}
