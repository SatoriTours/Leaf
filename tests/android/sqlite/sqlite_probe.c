#include <jni.h>
#include <stdint.h>
#include <stddef.h>
extern int leaf_jni_check_owner(JNIEnv *);
extern void leaf_jni_fail(JNIEnv *,const char *,const char *);
extern int leaf_sqlite_configure(const uint8_t *,size_t,const uint8_t *,size_t);
extern int64_t leaf_sqlite_probe(int);
JNIEXPORT jint JNICALL Java_dev_leaf_testsqlite_MainActivity_configure(JNIEnv *env,jobject self,jbyteArray path,jbyteArray sql) {
    (void)self;
    if(!leaf_jni_check_owner(env))return 1;
    if(path==NULL || sql==NULL)return 1;
    jsize pn=(*env)->GetArrayLength(env,path),sn=(*env)->GetArrayLength(env,sql);
    if((*env)->ExceptionCheck(env) || pn<=0 || pn>1048576 || sn<=0 || sn>1048576)return 1;
    jbyte *p=(*env)->GetByteArrayElements(env,path,NULL);
    if(p==NULL || (*env)->ExceptionCheck(env)) {
        if(p)(*env)->ReleaseByteArrayElements(env,path,p,JNI_ABORT);
        return 1;
    }
    jbyte *s=(*env)->GetByteArrayElements(env,sql,NULL);
    int status=1;
    if(s!=NULL && !(*env)->ExceptionCheck(env))status=leaf_sqlite_configure((const uint8_t *)p,(size_t)pn,(const uint8_t *)s,(size_t)sn);
    if(s)(*env)->ReleaseByteArrayElements(env,sql,s,JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env,path,p,JNI_ABORT);
    return status;
}
JNIEXPORT jlong JNICALL Java_dev_leaf_testsqlite_MainActivity_marker(JNIEnv *env,jobject self,jint which) {
    (void)self;
    if(!leaf_jni_check_owner(env))return -3;
    return (jlong)leaf_sqlite_probe(which);
}
