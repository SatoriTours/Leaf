#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "leaf_android.h"
extern void NimMain(void);
extern int leaf_controls_probe(int);
typedef struct Native {
    uint64_t session,mount,revision,check,toggle,reject,disabled,model;
    uint8_t *staged;
    size_t staged_length;
    int checked,toggled,rejected,fail_effects;
    double progress;
    unsigned kinds;
} Native;
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const uint8_t *p) { return u32(p)|((uint64_t)u32(p+4)<<32); }
static const uint8_t *string(const uint8_t *d,size_t length,size_t *at,uint32_t *size) {
    assert(*at+4<=length);*size=u32(d+*at);*at+=4;
    assert(*size<=length-*at);const uint8_t *p=d+*at;*at+=*size;return p;
}
static int label(const uint8_t *value,uint32_t size,const char *expected) {
    return size==strlen(expected) && !memcmp(value,expected,size);
}
static void frame(Native *n,const uint8_t *d,size_t length,int install) {
    assert(length>=36);
    uint32_t magic=u32(d);
    assert(magic==0x3156414c || magic==0x3256414c || magic==0x3356414c);
    int editors=magic!=0x3156414c,controls=magic==0x3356414c;
    if(u64(d+4)) { n->session=u64(d+4);n->mount=u64(d+12);n->revision=u64(d+20); }
    size_t at=36;
    for(uint32_t i=0;i<u32(d+28);i++) {
        assert(at+36<=length);uint64_t handle=u64(d+at+4);uint32_t kind=u32(d+at+24);at+=36;
        uint32_t size;string(d,length,&at,&size);
        const uint8_t *value=string(d,length,&at,&size);
        if(kind==5 && label(value,size,"接受")) n->check=handle;
        if(kind==6) n->toggle=handle;
        if(kind==5 && label(value,size,"拒绝")) n->reject=handle;
        if(kind==5 && label(value,size,"禁用")) n->disabled=handle;
        if(kind==3 && label(value,size,"程序更新")) n->model=handle;
        assert(kind<=11);n->kinds|=1u<<kind;
        if(editors) { string(d,length,&at,&size);string(d,length,&at,&size); }
        if(controls) {
            assert(at+12<=length && u32(d+at)<=1);at+=4;
            uint64_t bits=u64(d+at);double progress;memcpy(&progress,&bits,sizeof(progress));at+=8;
            if(install && kind==7) n->progress=progress;
        }
    }
    assert((size_t)u32(d+32)<=(length-at)/72);at+=(size_t)u32(d+32)*72;
    if(editors) {
        assert(at+4<=length);uint32_t writes=u32(d+at);at+=4;
        for(uint32_t i=0;i<writes;i++) {
            assert(at+20<=length);uint64_t handle=u64(d+at);uint32_t count=u32(d+at+16);at+=20;
            for(uint32_t j=0;j<count;j++) {
                assert(at+4<=length);uint32_t kind=u32(d+at);at+=4;
                uint32_t size;string(d,length,&at,&size);assert(at+16<=length);
                if(install && kind==2) {
                    if(handle==n->check) n->checked=(int)u32(d+at);
                    if(handle==n->toggle) n->toggled=(int)u32(d+at);
                    if(handle==n->reject) n->rejected=(int)u32(d+at);
                }
                at+=16;
            }
        }
    }
    assert(at==length);
}
static int32_t command(void *ctx,uint32_t tag,const uint8_t *d,size_t length,
                       double w,double h,double *measured) {
    (void)w;(void)h;Native *n=ctx;
    switch(tag) {
    case 1: measured[0]=200;measured[1]=40;break;
    case 2:
        free(n->staged);n->staged=malloc(length);assert(n->staged);
        memcpy(n->staged,d,length);n->staged_length=length;frame(n,d,length,0);break;
    case 3: frame(n,n->staged,n->staged_length,1);break;
    case 4: free(n->staged);n->staged=NULL;break;
    case 5: frame(n,d,length,1);break;
    case 6: frame(n,d,length,0);break;
    case 7: free(n->staged);n->staged=NULL;break;
    case 8: if(n->fail_effects) return 1;frame(n,d,length,1);break;
    case 9:case 10:break;
    default:return 1; /* A checked control must never query a text selection. */
    }
    return 0;
}
/* Keep declaration here until ABI3 is implemented, allowing the pre-feature
 * executable to establish the actual unsupported-version failure first. */
extern int32_t leaf_android_checked(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                                  uint64_t,uint64_t,uint64_t,uint32_t);
#ifndef LEAF_CONTROLS_VERSION_RED
static int32_t checked(uint64_t owner,uint64_t activity,Native *n,uint64_t handle,
                       uint64_t seq,uint32_t value) {
    return leaf_android_checked(owner,activity,n->session,n->mount,handle,seq,n->revision,1,value);
}
#endif
int main(void) {
    NimMain();Native n={0};uint64_t owner=0,mount=0;
    LeafAndroidCallbacks cb={3,sizeof(cb),&n,command};
    int32_t status=leaf_android_create(&cb,&owner);
    if(status!=0) { printf("ABI3 create rejected: status=%d expected=0\n",status);return 1; }
#ifndef LEAF_CONTROLS_VERSION_RED
    assert(leaf_android_attach(owner,400,700,1,&mount)==0);
    assert(n.check && n.toggle && n.reject && n.disabled && n.model && n.progress==42.5);
    assert((n.kinds&0x7e0)==0x7e0 && !n.checked && !n.toggled);
    assert(leaf_android_phase(owner,mount,1)==0);
    assert(leaf_android_checked(owner,mount,n.session+1,n.mount,n.check,1,n.revision,1,1)==5);
    assert(leaf_android_checked(owner,mount,n.session,n.mount,n.check,1,n.revision+1,1,1)==5);
    assert(leaf_android_checked(owner,mount,n.session,n.mount,n.check,1,n.revision,2,1)==5);
    assert(leaf_android_input(owner,mount,n.session,n.mount,n.check,1,n.revision,1,1,NULL,0,0,0,0)==5);
    assert(checked(owner,mount,&n,n.check,1,2)==5);
    n.checked=1;
    assert(checked(owner,mount,&n,n.check,1,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && n.checked && n.toggled && leaf_controls_probe(2)==1);
    assert(checked(owner,mount,&n,n.toggle,1,0)==5);
    n.toggled=0;
    assert(checked(owner,mount,&n,n.toggle,2,0)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && !n.checked && !n.toggled && leaf_controls_probe(2)==2);
    uint64_t revision=n.revision;n.rejected=1;
    assert(checked(owner,mount,&n,n.reject,3,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && !n.rejected && n.revision==revision && leaf_controls_probe(3)==1);
    assert(checked(owner,mount,&n,n.disabled,4,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && leaf_controls_probe(4)==0);
    assert(leaf_android_phase(owner,mount,2)==0);
    assert(checked(owner,mount,&n,n.check,5,1)==5);
    assert(leaf_android_phase(owner,mount,1)==0);
    assert(leaf_android_event(owner,mount,n.session,n.mount,n.model,5,n.revision,1,0)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && n.progress==77.25 && n.checked && n.toggled);
    n.rejected=1;n.fail_effects=1;
    assert(checked(owner,mount,&n,n.reject,6,1)==0);
    (void)leaf_android_phase(owner,mount,3);
    assert(leaf_android_phase(owner,mount,3)==5);
    assert(leaf_android_close(owner)==0 && leaf_controls_probe(5)==1);
    puts("Android remaining controls C ABI: passed");
#else
    (void)mount;
    assert(leaf_android_close(owner)==0);
#endif
    return 0;
}
