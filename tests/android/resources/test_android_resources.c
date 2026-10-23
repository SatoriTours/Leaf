#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "leaf_android.h"
_Static_assert(sizeof(((LeafAndroidResources *)0)->data_length)==sizeof(size_t),"resource length ABI");
_Static_assert(offsetof(LeafAndroidResources,context)==8,"resource context ABI");
extern void NimMain(void);
extern int32_t leaf_resources_probe(int32_t);
extern void leaf_resources_fixture(int32_t,int32_t);
static unsigned reads, queries;
static int read_mode,fail_native;
static int32_t read_asset(void *context,const uint8_t *path,size_t path_length,
                          uint8_t *out,size_t capacity,size_t *length) {
    assert(context==&reads && path && path_length==10 && memcmp(path,"binary.bin",10)==0);
    assert(length && *length==0);
    if(read_mode==1)return 6;
    if(!out && capacity==0) {
        ++queries; *length=read_mode==2 ? SIZE_MAX : 3; return 0;
    }
    ++reads;
    assert(capacity==3 && out);
    if(read_mode==3) { *length=4;return 0; }
    memcpy(out,"a\0b",3);*length=3;return 0;
}
static int32_t command(void *context,uint32_t tag,const uint8_t *bytes,size_t length,
                       double width,double height,double *size) {
    (void)context;(void)bytes;(void)length;(void)width;(void)height;
    if(tag==1) {assert(size);size[0]=100;size[1]=40;}
    if(tag==7 && fail_native)return 1;
    return 0;
}
int main(int argc,char **argv) {
    assert(argc==3);
    NimMain();
    LeafAndroidCallbacks views={1,sizeof(views),NULL,command};
    LeafAndroidResources resources={1,sizeof(resources),&reads,read_asset,
        (const uint8_t *)argv[1],strlen(argv[1]),(const uint8_t *)argv[2],strlen(argv[2])};
    uint64_t owner=0;
    assert(leaf_android_create(&views,&owner)==5 && owner==0 && leaf_resources_probe(1)==0);
    assert(leaf_android_create_with_resources(&views,NULL,&owner)==1 && owner==0);
    resources.abi_version=2;
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==0);
    resources.abi_version=1;resources.struct_size--;
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==0);
    resources.struct_size++;owner=42;
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==42);
    owner=0;
    const uint8_t *valid=resources.data_directory; size_t valid_n=resources.data_length;
    resources.data_directory=(const uint8_t *)1; resources.data_length=SIZE_MAX;
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==0);
    resources.data_directory=valid;resources.data_length=valid_n;
    resources.read_asset=NULL;
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==0);
    resources.read_asset=read_asset;
    static const uint8_t invalid_utf8[]={0xed,0xa0,0x80};
    resources.data_directory=invalid_utf8;resources.data_length=sizeof(invalid_utf8);
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==0);
    static const uint8_t with_nul[]={'/','t','m','p',0,'x'};
    resources.data_directory=with_nul;resources.data_length=sizeof(with_nul);
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==1 && owner==0);
    resources.data_directory=valid;resources.data_length=valid_n;
    for(read_mode=1;read_mode<=3;++read_mode) {
        unsigned previous=reads;
        assert(leaf_android_create_with_resources(&views,&resources,&owner)==6 && owner==0);
        if(read_mode==2)assert(reads==previous);
        assert(leaf_resources_probe(0)==0);
    }
    read_mode=0;
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==0 && owner);
    assert(reads>0 && queries>0 && leaf_resources_probe(0)==1);
    /* The caller may immediately reuse the borrowed callback table. */
    resources.context=NULL;resources.read_asset=NULL;
    resources.data_directory=(const uint8_t *)1;resources.data_length=SIZE_MAX;
    assert(leaf_resources_probe(0)==1);
    resources.context=&reads;resources.read_asset=read_asset;
    resources.data_directory=valid;resources.data_length=valid_n;
    uint64_t mount=0;
    assert(leaf_android_attach(owner,400,600,1,&mount)==0 && mount);
    fail_native=1;
    assert(leaf_android_close(owner)==6 && leaf_resources_probe(0)==1);
    fail_native=0;
    assert(leaf_android_close(owner)==0 && leaf_resources_probe(0)==0);
    owner=0;
    leaf_resources_fixture(1,0);
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==6 && owner==0);
    assert(leaf_resources_probe(0)==0);
    leaf_resources_fixture(2,1);
    assert(leaf_android_create_with_resources(&views,&resources,&owner)==6 && owner);
    assert(leaf_resources_probe(0)==1);
    assert(leaf_android_close(owner)==6 && leaf_resources_probe(0)==1);
    leaf_resources_fixture(2,0);
    assert(leaf_android_close(owner)==0 && leaf_resources_probe(0)==0);
    assert(leaf_android_close(owner)==5);
    puts("Android host resources C ABI: passed");
    return 0;
}
