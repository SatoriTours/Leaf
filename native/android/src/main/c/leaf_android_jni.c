/* One C context per retained Runtime; attached View and application AssetManager
 * have distinct global references. Assets survive Activity detach and are
 * released only after terminal Runtime cleanup succeeds.
 * No Activity is retained after successful detach, no JNIEnv is cached. Java
 * exceptions are held as local refs during one enclosing JNI call so Nim can
 * replay accepted state, then returned/thrown as the original primary error. */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include "leaf_android.h"
#include "leaf_jni_internal.h"

typedef struct AndroidContext {
    uint64_t owner;
    JavaVM *vm;
    jobject view;
    jobject assets;
    AAssetManager *asset_manager;
    jmethodID measure,stage,apply,discard,replay,bind,dispose,edit,active,selection,geometry,protection;
    jthrowable primary; /* local ref: cleared before the JNI entry returns */
    struct AndroidContext *next;
} AndroidContext;
static AndroidContext *contexts;
static void free_context(JNIEnv *env,AndroidContext *ctx) {
    if(ctx->assets) (*env)->DeleteGlobalRef(env,ctx->assets);
    free(ctx);
}
static int32_t read_asset(void *raw,const uint8_t *path,size_t path_length,
                          uint8_t *output,size_t capacity,size_t *length) {
    AndroidContext *ctx=raw;
    if(!ctx || !ctx->asset_manager || !path || !path_length || path_length>4096 ||
       !length || *length || memchr(path,0,path_length))return 1;
    char name[4097];memcpy(name,path,path_length);name[path_length]=0;
    AAsset *asset=AAssetManager_open(ctx->asset_manager,name,AASSET_MODE_STREAMING);
    if(!asset)return 1;
    off64_t total=AAsset_getLength64(asset);
    int32_t status=1;
    if(total<0 || (uint64_t)total>SIZE_MAX)goto done;
    if(!output && capacity==0) { *length=(size_t)total;status=0;goto done; }
    if(!output || capacity!=(size_t)total || capacity>1048576)goto done;
    size_t offset=0;
    while(offset<capacity) {
        int count=AAsset_read(asset,output+offset,capacity-offset);
        if(count<=0)goto done;
        offset+=(size_t)count;
    }
    *length=offset;status=0;
done:
    AAsset_close(asset);
    return status;
}


static AndroidContext *lookup(uint64_t owner) {
    for (AndroidContext *p=contexts;p;p=p->next) if(p->owner==owner) return p;
    return NULL;
}
static void capture(JNIEnv *env,AndroidContext *ctx) {
    if (!(*env)->ExceptionCheck(env)) return;
    jthrowable error=(*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    if(ctx->primary) (*env)->DeleteLocalRef(env,error);
    else ctx->primary=error;
}
static int32_t command(void *raw,uint32_t tag,const uint8_t *data,size_t length,
                       double width,double height,double *measured) {
    AndroidContext *ctx=raw;
    JNIEnv *env=NULL;
    if((*ctx->vm)->GetEnv(ctx->vm,(void **)&env,JNI_VERSION_1_6)!=JNI_OK || !env) return 1;
    if(!ctx->view) return tag==7 || tag==4 ? 0 : 1;
    if(length>67108864 || (length && !data)) return 1;
    if((*env)->PushLocalFrame(env,16)<0) { capture(env,ctx); return 1; }
    jbyteArray payload=NULL;
    if(length) {
        payload=(*env)->NewByteArray(env,(jsize)length);
        if(payload) (*env)->SetByteArrayRegion(env,payload,0,(jsize)length,(const jbyte *)data);
    }
    if(!(*env)->ExceptionCheck(env)) switch(tag) {
    case 1: case 11: {
        jdoubleArray size=tag==1 ? (*env)->CallObjectMethod(env,ctx->view,ctx->measure,payload,width,height)
            : (*env)->CallObjectMethod(env,ctx->view,ctx->selection,payload);
        if(!(*env)->ExceptionCheck(env) && size && (*env)->GetArrayLength(env,size)==2 && measured)
            (*env)->GetDoubleArrayRegion(env,size,0,2,measured);
        else if(!(*env)->ExceptionCheck(env))
            leaf_jni_fail(env,"java/lang/IllegalStateException","Invalid Android measurement");
        break;
    }
    case 2: (*env)->CallVoidMethod(env,ctx->view,ctx->stage,payload);break;
    case 3: (*env)->CallVoidMethod(env,ctx->view,ctx->apply);break;
    case 4: (*env)->CallVoidMethod(env,ctx->view,ctx->discard);break;
    case 5: (*env)->CallVoidMethod(env,ctx->view,ctx->replay,payload);break;
    case 6: (*env)->CallVoidMethod(env,ctx->view,ctx->bind,payload);break;
    case 7: (*env)->CallVoidMethod(env,ctx->view,ctx->dispose);break;
    case 8: (*env)->CallVoidMethod(env,ctx->view,ctx->edit,payload);break;
    case 9: (*env)->CallVoidMethod(env,ctx->view,ctx->active,JNI_TRUE);break;
    case 10: (*env)->CallVoidMethod(env,ctx->view,ctx->active,JNI_FALSE);break;
    case 12: (*env)->CallVoidMethod(env,ctx->view,ctx->geometry,payload);break;
    default: leaf_jni_fail(env,"java/lang/IllegalArgumentException","Unknown Android command");break;
    }
    int failed=(*env)->ExceptionCheck(env);
    jthrowable error=failed ? (*env)->ExceptionOccurred(env) : NULL;
    if(failed) (*env)->ExceptionClear(env);
    /* Move a thrown local out of the callback frame before retaining it. */
    error=(*env)->PopLocalFrame(env,error);
    if(error) {
        if(ctx->primary) (*env)->DeleteLocalRef(env,error); else ctx->primary=error;
    }
    if(!failed && tag==7) {
        (*env)->DeleteGlobalRef(env,ctx->view);
        ctx->view=NULL;
    }
    return failed ? 1 : 0;
}

typedef struct CallResult {
    jobject object;
    jfieldID owner,mount,status,failure;
} CallResult;
static CallResult result(JNIEnv *env) {
    CallResult r={0};
    jclass cls=(*env)->FindClass(env,"dev/leaf/runtime/AndroidCall");
    if(!cls) return r;
    jmethodID ctor=(*env)->GetMethodID(env,cls,"<init>","()V");
    if(ctor) r.object=(*env)->NewObject(env,cls,ctor);
    if(r.object) {
        r.owner=(*env)->GetFieldID(env,cls,"owner","J");
        r.mount=(*env)->GetFieldID(env,cls,"mount","J");
        r.status=(*env)->GetFieldID(env,cls,"status","I");
        r.failure=(*env)->GetFieldID(env,cls,"failure","Ljava/lang/Throwable;");
    }
    (*env)->DeleteLocalRef(env,cls);
    return r;
}
static jobject finish_result(JNIEnv *env,CallResult r,AndroidContext *ctx,
                             int32_t status,uint64_t owner,uint64_t mount) {
    (*env)->SetLongField(env,r.object,r.owner,(jlong)owner);
    (*env)->SetLongField(env,r.object,r.mount,(jlong)mount);
    (*env)->SetIntField(env,r.object,r.status,status);
    if(ctx && ctx->primary) {
        (*env)->SetObjectField(env,r.object,r.failure,ctx->primary);
        (*env)->DeleteLocalRef(env,ctx->primary); ctx->primary=NULL;
    }
    return r.object;
}
static void finish(JNIEnv *env,AndroidContext *ctx,int32_t status) {
    if(ctx && ctx->primary) {
        (*env)->Throw(env,ctx->primary);
        (*env)->DeleteLocalRef(env,ctx->primary); ctx->primary=NULL;
    } else if(status!=0 && status!=5)
        leaf_jni_fail(env,"java/lang/IllegalStateException","Leaf Android native operation failed");
}
static jobject create_owner(JNIEnv *env,jobject assets,jbyteArray data,jbyteArray cache) {
    if(!leaf_jni_check_owner(env)) return NULL;
    CallResult r=result(env);
    if(!r.object || (*env)->ExceptionCheck(env)) return NULL;
    AndroidContext *ctx=calloc(1,sizeof(*ctx));
    if(!ctx) { leaf_jni_fail(env,"java/lang/OutOfMemoryError","Leaf context allocation failed");return NULL; }
    if((*env)->GetJavaVM(env,&ctx->vm)!=JNI_OK) { free_context(env,ctx);return NULL; }
    LeafAndroidCallbacks callbacks={5,sizeof(callbacks),ctx,command};
    uint64_t owner=0;
    int32_t status;
    if(assets) {
        if(!data || !cache) {
            free_context(env,ctx);
            leaf_jni_fail(env,"java/lang/IllegalArgumentException","Missing Leaf resource roots");return NULL;
        }
        jsize dn=(*env)->GetArrayLength(env,data),cn=(*env)->GetArrayLength(env,cache);
        if((*env)->ExceptionCheck(env)) {free_context(env,ctx);return NULL;}
        if(dn<=0 || cn<=0 || dn>4096 || cn>4096) {
            free_context(env,ctx);
            leaf_jni_fail(env,"java/lang/IllegalArgumentException","Invalid Leaf resource root length");return NULL;
        }
        ctx->assets=(*env)->NewGlobalRef(env,assets);
        if(ctx->assets)ctx->asset_manager=AAssetManager_fromJava(env,ctx->assets);
        if(!ctx->assets || !ctx->asset_manager || (*env)->ExceptionCheck(env)) {
            free_context(env,ctx);
            leaf_jni_fail(env,"java/lang/IllegalStateException","Leaf AssetManager unavailable");return NULL;
        }
        jbyte *db=(*env)->GetByteArrayElements(env,data,NULL);
        jbyte *cb=NULL;
        if(db && !(*env)->ExceptionCheck(env))cb=(*env)->GetByteArrayElements(env,cache,NULL);
        if(!db || !cb || (*env)->ExceptionCheck(env)) {
            if(db)(*env)->ReleaseByteArrayElements(env,data,db,JNI_ABORT);
            if(cb)(*env)->ReleaseByteArrayElements(env,cache,cb,JNI_ABORT);
            free_context(env,ctx);
            leaf_jni_fail(env,"java/lang/OutOfMemoryError","Leaf resource roots unavailable");return NULL;
        }
        LeafAndroidResources resources={1,sizeof(resources),ctx,read_asset,
            (const uint8_t *)db,(size_t)dn,(const uint8_t *)cb,(size_t)cn};
        status=leaf_android_create_with_resources(&callbacks,&resources,&owner);
        (*env)->ReleaseByteArrayElements(env,cache,cb,JNI_ABORT);
        (*env)->ReleaseByteArrayElements(env,data,db,JNI_ABORT);
    } else status=leaf_android_create(&callbacks,&owner);
    if(owner) { ctx->owner=owner;ctx->next=contexts;contexts=ctx; }
    jobject answer=finish_result(env,r,ctx,status,owner,0);
    if(!owner) free_context(env,ctx);
    return answer;
}
JNIEXPORT jobject JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_createOwner(JNIEnv *env,jobject self) {
    (void)self;
    return create_owner(env,NULL,NULL,NULL);
}
JNIEXPORT jobject JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_createOwnerWithResources(
        JNIEnv *env,jobject self,jobject assets,jbyteArray data,jbyteArray cache) {
    (void)self;
    if(!assets) {
        leaf_jni_fail(env,"java/lang/IllegalArgumentException","Missing Leaf AssetManager");return NULL;
    }
    return create_owner(env,assets,data,cache);
}
JNIEXPORT jobject JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_attach(JNIEnv *env,jobject self,
        jlong owner,jobject view,jdouble width,jdouble height,jdouble scale) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return NULL;
    AndroidContext *ctx=lookup((uint64_t)owner);
    CallResult r=result(env);
    if(!r.object || (*env)->ExceptionCheck(env)) return NULL;
    if(!ctx || ctx->view || !view) return finish_result(env,r,NULL,5,(uint64_t)owner,0);
    ctx->view=(*env)->NewGlobalRef(env,view);
    if(!ctx->view || (*env)->ExceptionCheck(env)) {
        if(ctx->view) (*env)->DeleteGlobalRef(env,ctx->view);
        ctx->view=NULL;return NULL;
    }
    jclass cls=(*env)->GetObjectClass(env,view);
    if(cls) {
        ctx->measure=(*env)->GetMethodID(env,cls,"measureNative","([BDD)[D");
        ctx->stage=(*env)->GetMethodID(env,cls,"stageNative","([B)V");
        ctx->apply=(*env)->GetMethodID(env,cls,"applyNative","()V");
        ctx->discard=(*env)->GetMethodID(env,cls,"discardNative","()V");
        ctx->replay=(*env)->GetMethodID(env,cls,"replayNative","([B)V");
        ctx->bind=(*env)->GetMethodID(env,cls,"bindNative","([B)V");
        ctx->dispose=(*env)->GetMethodID(env,cls,"disposeNative","()V");
        ctx->edit=(*env)->GetMethodID(env,cls,"editNative","([B)V");
        ctx->active=(*env)->GetMethodID(env,cls,"editorsActiveNative","(Z)V");
        ctx->selection=(*env)->GetMethodID(env,cls,"selectionNative","([B)[D");
        ctx->geometry=(*env)->GetMethodID(env,cls,"geometryNative","([B)V");
        ctx->protection=(*env)->GetMethodID(env,cls,"collectProtectionNative","(J)V");
        (*env)->DeleteLocalRef(env,cls);
    }
    if((*env)->ExceptionCheck(env)) {
        (*env)->DeleteGlobalRef(env,ctx->view);ctx->view=NULL;return NULL;
    }
    uint64_t mount=0;
    int32_t status=leaf_android_attach((uint64_t)owner,width,height,scale,&mount);
    if((status==1 || status==5) && ctx->view) {
        (*env)->DeleteGlobalRef(env,ctx->view);ctx->view=NULL;
    }
    return finish_result(env,r,ctx,status,(uint64_t)owner,mount);
}
JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_phase(JNIEnv *env,jobject self,
        jlong owner,jlong mount,jint phase) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE;
    AndroidContext *ctx=lookup((uint64_t)owner);
    if(phase==3 && ctx && ctx->view) {
        (*env)->CallVoidMethod(env,ctx->view,ctx->protection,mount);
        if((*env)->ExceptionCheck(env)) {
            capture(env,ctx);finish(env,ctx,6);return JNI_FALSE;
        }
    }
    int32_t status=leaf_android_phase((uint64_t)owner,(uint64_t)mount,(uint32_t)phase);
    finish(env,ctx,status);return status==0;
}
JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_event(JNIEnv *env,jobject self,
        jlong owner,jlong activityMount,jlong session,jlong eventMount,jlong handle,
        jlong sequence,jlong revision,jlong binding,jint kind) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE;
    AndroidContext *ctx=lookup((uint64_t)owner);
    int32_t status=leaf_android_event((uint64_t)owner,(uint64_t)activityMount,(uint64_t)session,
        (uint64_t)eventMount,(uint64_t)handle,(uint64_t)sequence,(uint64_t)revision,(uint64_t)binding,(uint32_t)kind);
    finish(env,ctx,status);return status==0;
}
JNIEXPORT void JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_close(JNIEnv *env,jobject self,jlong owner) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return;
    AndroidContext *ctx=lookup((uint64_t)owner);
    int32_t status=leaf_android_close((uint64_t)owner);
    finish(env,ctx,status);
    if(status==0 && ctx) {
        AndroidContext **p=&contexts;while(*p!=ctx) p=&(*p)->next;
        *p=ctx->next;free_context(env,ctx);
    }
}

JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_input(JNIEnv *env,jobject self,
        jlong owner,jlong activityMount,jlong session,jlong eventMount,jlong handle,
        jlong sequence,jlong revision,jlong binding,jint kind,jbyteArray value,
        jint phase,jint anchor,jint caret) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE; /* before pin/copy */
    if(!value) return JNI_FALSE;
    jsize length=(*env)->GetArrayLength(env,value);
    if(length>1048576) return JNI_FALSE;
    jbyte *bytes=length ? (*env)->GetByteArrayElements(env,value,NULL) : NULL;
    if(length && !bytes) return JNI_FALSE; /* preserve an allocation exception */
    int32_t status=leaf_android_input((uint64_t)owner,(uint64_t)activityMount,(uint64_t)session,
        (uint64_t)eventMount,(uint64_t)handle,(uint64_t)sequence,(uint64_t)revision,
        (uint64_t)binding,(uint32_t)kind,(const uint8_t *)bytes,(size_t)length,
        (uint32_t)phase,(int32_t)anchor,(int32_t)caret);
    if(bytes) (*env)->ReleaseByteArrayElements(env,value,bytes,JNI_ABORT);
    finish(env,lookup((uint64_t)owner),status);
    return status==0;
}

JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_checked(JNIEnv *env,jobject self,
        jlong owner,jlong activityMount,jlong session,jlong eventMount,jlong handle,
        jlong sequence,jlong revision,jlong binding,jboolean checked) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE;
    int32_t status=leaf_android_checked((uint64_t)owner,(uint64_t)activityMount,(uint64_t)session,
        (uint64_t)eventMount,(uint64_t)handle,(uint64_t)sequence,(uint64_t)revision,
        (uint64_t)binding,checked ? 1u : 0u);
    finish(env,lookup((uint64_t)owner),status);
    return status==0;
}

JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_scroll(JNIEnv *env,jobject self,
        jlong owner,jlong activityMount,jlong session,jlong eventMount,jlong handle,
        jlong sequence,jlong revision,jlong source,jdouble offset) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE;
    int32_t status=leaf_android_scroll((uint64_t)owner,(uint64_t)activityMount,(uint64_t)session,
        (uint64_t)eventMount,(uint64_t)handle,(uint64_t)sequence,(uint64_t)revision,(uint64_t)source,offset);
    finish(env,lookup((uint64_t)owner),status);
    return status==0;
}

JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_protect(JNIEnv *env,jobject self,
        jlong owner,jlong activityMount,jlong session,jlong eventMount,jlong handle,
        jlong sequence,jlong revision,jlong binding,jint reasons) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE;
    int32_t status=leaf_android_protect((uint64_t)owner,(uint64_t)activityMount,(uint64_t)session,
        (uint64_t)eventMount,(uint64_t)handle,(uint64_t)sequence,(uint64_t)revision,(uint64_t)binding,
        (uint32_t)reasons);
    /* Data-only: this call cannot produce a platform primary. A focus callback
     * during accepted replay must leave the enclosing command's primary rooted
     * until that JNI call returns, including when this fact is rejected. */
    if(status!=0 && status!=5)
        leaf_jni_fail(env,"java/lang/IllegalStateException","Leaf Android protection fact failed");
    return status==0;
}

JNIEXPORT jboolean JNICALL Java_dev_leaf_runtime_AndroidViewsBridge_back(JNIEnv *env,jobject self,
        jlong owner,jlong activityMount,jlong session,jlong eventMount,jlong handle,
        jlong sequence,jlong revision,jlong binding,jlong request,jlong router,
        jlong history,jlong current,jlong previous,jint depth,jint phase) {
    (void)self;
    if(!leaf_jni_check_owner(env)) return JNI_FALSE;
    const LeafAndroidBackFact fact={
        (uint64_t)session,(uint64_t)eventMount,(uint64_t)handle,(uint64_t)binding,
        (uint64_t)sequence,(uint64_t)revision,(uint64_t)request,(uint64_t)router,
        (uint64_t)history,(uint64_t)current,(uint64_t)previous,(uint32_t)depth,(uint32_t)phase};
    int32_t status=leaf_android_back((uint64_t)owner,(uint64_t)activityMount,&fact);
    /* Data-only, including a rejected callback nested in replay. Do not clear
     * an enclosing command's primary exception reference here. */
    if(status!=0 && status!=5)
        leaf_jni_fail(env,"java/lang/IllegalStateException","Leaf Android back fact failed");
    return status==0;
}
