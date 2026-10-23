#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "leaf_android.h"
extern void NimMain(void);
extern int leaf_editors_probe(int);
typedef struct Native {
    uint64_t session,mount,revision,editor,model,reset,binding;
    uint8_t *staged;
    size_t staged_length,text_length;
    char text[4096];
    int anchor,caret,fail_effects,active;
} Native;
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const uint8_t *p) { return u32(p)|((uint64_t)u32(p+4)<<32); }
static const uint8_t *string(const uint8_t *d,size_t length,size_t *at,uint32_t *size) {
    assert(*at+4<=length);*size=u32(d+*at);*at+=4;
    assert(*size<=length-*at);const uint8_t *p=d+*at;*at+=*size;return p;
}
static void text(Native *n,const void *value,size_t len) {
    assert(len<sizeof(n->text));memcpy(n->text,value,len);n->text_length=len;
}
static void frame(Native *n,const uint8_t *d,size_t length,int install) {
    assert(length>=36);
    uint32_t magic=u32(d);assert(magic==0x3156414c || magic==0x3256414c);
    int editors=magic==0x3256414c;
    if(u64(d+4)) { n->session=u64(d+4);n->mount=u64(d+12);n->revision=u64(d+20); }
    size_t at=36;
    for(uint32_t i=0;i<u32(d+28);i++) {
        assert(at+36<=length);uint64_t handle=u64(d+at+4);uint32_t kind=u32(d+at+24);at+=36;
        uint32_t size;string(d,length,&at,&size);
        const uint8_t *label=string(d,length,&at,&size);
        if(kind==4) n->editor=handle;
        if(kind==3 && size==12 && !memcmp(label,"模型更新",12)) n->model=handle;
        if(kind==3 && size==6 && !memcmp(label,"重置",6)) n->reset=handle;
        if(editors) { string(d,length,&at,&size);string(d,length,&at,&size); }
    }
    assert((size_t)u32(d+32)<=(length-at)/72);at+=(size_t)u32(d+32)*72;
    if(editors) {
        assert(at+4<=length);uint32_t writes=u32(d+at);at+=4;
        for(uint32_t i=0;i<writes;i++) {
            assert(at+20<=length);uint64_t handle=u64(d+at),binding=u64(d+at+8);
            uint32_t count=u32(d+at+16);at+=20;
            if(install && handle==n->editor) n->binding=binding;
            for(uint32_t j=0;j<count;j++) {
                assert(at+4<=length);uint32_t kind=u32(d+at);at+=4;
                uint32_t size;const uint8_t *value=string(d,length,&at,&size);
                assert(at+16<=length);
                if(install && handle==n->editor) {
                    if(kind==1) text(n,value,size);
                    if(kind==1 || kind==3) { n->anchor=(int)u32(d+at+4);n->caret=(int)u32(d+at+8); }
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
    case 9: n->active=1;break;
    case 10: n->active=0;break;
    case 11: measured[0]=n->anchor;measured[1]=n->caret;break;
    default: return 1;
    }
    return 0;
}
static int32_t input(uint64_t owner,uint64_t activity,Native *n,uint64_t seq,
                     const char *value,size_t length,uint32_t phase,uint64_t binding) {
    return leaf_android_input(owner,activity,n->session,n->mount,n->editor,seq,n->revision,
        binding,1,(const uint8_t *)value,length,phase,n->anchor,n->caret);
}
static void click(uint64_t owner,uint64_t activity,Native *n,uint64_t seq,uint64_t handle) {
    assert(handle);
    assert(leaf_android_event(owner,activity,n->session,n->mount,handle,seq,n->revision,1,0)==0);
    assert(leaf_android_phase(owner,activity,3)==0);
}
int main(void) {
    NimMain();Native n={0};uint64_t owner=0,mount=0;
    LeafAndroidCallbacks cb={2,sizeof(cb),&n,command};
    assert(leaf_android_create(&cb,&owner)==0);
    assert(leaf_android_attach(owner,400,600,1,&mount)==0);
    assert(n.editor && n.model && n.reset && n.binding==1);
    assert(leaf_android_phase(owner,mount,1)==0 && n.active);
    assert(input(owner,mount,&n,1,"\xED\xA0\x80",3,0,1)==2);
    assert(leaf_android_input(owner,mount,n.session,n.mount,n.editor,1,n.revision,1,1,
        (const uint8_t *)(uintptr_t)1,SIZE_MAX,0,0,0)==3);
    const char value[]="中文\0😀";text(&n,value,sizeof(value)-1);n.anchor=n.caret=5;
    assert(input(owner,mount,&n,1,value,sizeof(value)-1,0,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && leaf_editors_probe(2)==1);
    text(&n,"reject",6);n.anchor=n.caret=6;
    assert(input(owner,mount,&n,2,"reject",6,0,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0);
    assert(n.text_length==sizeof(value)-1 && !memcmp(n.text,value,sizeof(value)-1) && n.caret==5);
    text(&n,"拼",3);n.anchor=n.caret=1;
    assert(input(owner,mount,&n,3,"拼",3,2,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0);
    click(owner,mount,&n,4,n.model);
    assert(n.text_length==3 && !memcmp(n.text,"拼",3));
    assert(input(owner,mount,&n,5,"拼",3,4,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0 && n.text_length==5 && !memcmp(n.text,"MODEL",5));
    click(owner,mount,&n,6,n.reset);
    assert(n.binding==2 && n.caret==7 && n.text_length==9 && !memcmp(n.text,"RESET😀",9));
    assert(input(owner,mount,&n,7,"stale",5,0,1)==5);
    assert(leaf_android_phase(owner,mount,2)==0 && !n.active);
    assert(input(owner,mount,&n,7,"paused",6,0,2)==5);
    assert(leaf_android_phase(owner,mount,1)==0);
    text(&n,"reject",6);n.anchor=n.caret=6;n.fail_effects=1;
    assert(input(owner,mount,&n,7,"reject",6,0,2)==0);
    (void)leaf_android_phase(owner,mount,3);
    assert(input(owner,mount,&n,8,"frozen",6,0,2)==5);
    assert(leaf_android_phase(owner,mount,3)==5);
    assert(leaf_android_close(owner)==0 && leaf_editors_probe(4)==1);
    puts("Android controlled editors C ABI: passed");return 0;
}
