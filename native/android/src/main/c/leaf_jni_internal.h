#ifndef LEAF_JNI_INTERNAL_H
#define LEAF_JNI_INTERNAL_H
#include <jni.h>
int leaf_jni_check_owner(JNIEnv *env);
void leaf_jni_fail(JNIEnv *env, const char *type, const char *message);
#endif
