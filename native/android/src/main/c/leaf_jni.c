/* JNI is only a thread/lifetime adapter. No JNIEnv, Activity or View reference
 * survives a call. App libraries compile Nim with --noMain:on: JNI_OnLoad must
 * never initialize Nim on an arbitrary library-loading worker. */
#include <jni.h>
#include <pthread.h>
#include <unistd.h>
#include "leaf_native.h"

extern void NimMain(void);
static pthread_mutex_t initialization_lock = PTHREAD_MUTEX_INITIALIZER;
static int initialized;
static pthread_t owner;

static void throw_ascii(JNIEnv *env, const char *type, const char *message) {
    if ((*env)->ExceptionCheck(env)) return; /* Preserve the original exception. */
    jclass cls = (*env)->FindClass(env, type);
    if (cls == NULL || (*env)->ExceptionCheck(env)) return;
    (void)(*env)->ThrowNew(env, cls, message); /* ASCII only; never user text. */
    (*env)->DeleteLocalRef(env, cls);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm;
    (void)reserved;
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL Java_dev_leaf_runtime_NativeBridge_initialize(
        JNIEnv *env, jobject receiver) {
    (void)receiver;
    /* Android's main Looper runs on the process main Linux thread. Reject
     * before NimMain even if a worker is the first caller. */
    if (gettid() != getpid()) {
        throw_ascii(env, "java/lang/IllegalStateException", "Leaf requires the Android main thread");
        return;
    }
    pthread_mutex_lock(&initialization_lock);
    if (!initialized) {
        owner = pthread_self();
        NimMain();
        initialized = 1;
    }
    pthread_mutex_unlock(&initialization_lock);
}

static int guard_owner(JNIEnv *env) {
    pthread_mutex_lock(&initialization_lock);
    int valid = initialized && pthread_equal(owner, pthread_self());
    pthread_mutex_unlock(&initialization_lock);
    if (!valid) throw_ascii(env, "java/lang/IllegalStateException", "Leaf is uninitialized or on a foreign thread");
    return valid;
}

JNIEXPORT jbyteArray JNICALL Java_dev_leaf_runtime_NativeBridge_copyUtf8(
        JNIEnv *env, jobject receiver, jbyteArray input) {
    (void)receiver;
    if (!guard_owner(env)) return NULL;
    if (input == NULL) {
        throw_ascii(env, "java/lang/IllegalArgumentException", "Null UTF-8 input");
        return NULL;
    }
    jsize length = (*env)->GetArrayLength(env, input);
    if ((*env)->ExceptionCheck(env)) return NULL;
    /* Do not pin/copy a known oversized Java array. Same limit as Leaf core. */
    if (length > 1048576) {
        throw_ascii(env, "java/lang/IllegalArgumentException", "UTF-8 input exceeds Leaf string budget");
        return NULL;
    }
    jbyte *borrowed = NULL;
    if (length != 0) {
        borrowed = (*env)->GetByteArrayElements(env, input, NULL);
        if (borrowed == NULL || (*env)->ExceptionCheck(env)) {
            if (borrowed != NULL) (*env)->ReleaseByteArrayElements(env, input, borrowed, JNI_ABORT);
            throw_ascii(env, "java/lang/OutOfMemoryError", "Could not borrow UTF-8 input");
            return NULL;
        }
    }
    LeafNativeBytes owned = {0};
    int32_t status = leaf_native_utf8_copy((const uint8_t *)borrowed, (size_t)length, &owned);
    if (borrowed != NULL) (*env)->ReleaseByteArrayElements(env, input, borrowed, JNI_ABORT);
    if ((*env)->ExceptionCheck(env)) {
        leaf_native_bytes_release(&owned);
        return NULL;
    }
    if (status != LEAF_NATIVE_OK) {
        leaf_native_bytes_release(&owned);
        throw_ascii(env, status == LEAF_NATIVE_NO_MEMORY ? "java/lang/OutOfMemoryError" :
            "java/lang/IllegalArgumentException", "Native UTF-8 copy rejected");
        return NULL;
    }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)owned.length);
    if (result == NULL || (*env)->ExceptionCheck(env)) {
        leaf_native_bytes_release(&owned);
        throw_ascii(env, "java/lang/OutOfMemoryError", "Could not allocate UTF-8 output");
        return NULL;
    }
    if (owned.length != 0) (*env)->SetByteArrayRegion(env, result, 0,
        (jsize)owned.length, (const jbyte *)owned.data);
    leaf_native_bytes_release(&owned);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->DeleteLocalRef(env, result);
        return NULL;
    }
    return result;
}

/* Shared by the synchronous Views adapter in this same library. */
int leaf_jni_check_owner(JNIEnv *env) { return guard_owner(env); }
void leaf_jni_fail(JNIEnv *env, const char *type, const char *message) {
    throw_ascii(env, type, message);
}
