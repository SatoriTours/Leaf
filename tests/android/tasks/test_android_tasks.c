#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include "leaf_android.h"
extern void NimMain(void);
extern int leaf_tasks_probe(int);
typedef struct Binding { uint64_t session,mount,revision,button; } Binding;
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const uint8_t *p) { return (uint64_t)u32(p)|((uint64_t)u32(p+4)<<32); }
static int32_t command(void *context,uint32_t tag,const uint8_t *data,size_t length,
                       double width,double height,double *measured) {
    (void)width;(void)height;
    Binding *b=context;
    if(tag==1) { measured[0]=160; measured[1]=40; }
    if(tag==2 || tag==6) {
        assert(data && length>=36 && u32(data)==0x3156414c);
        b->session=u64(data+4); b->mount=u64(data+12); b->revision=u64(data+20);
        size_t at=36;
        for(uint32_t i=0;i<u32(data+28);i++) {
            assert(at+36<=length);
            if(u32(data+at)==0 && u32(data+at+24)==3) b->button=u64(data+at+4);
            at+=36;
            for(unsigned j=0;j<2;j++) {
                assert(at+4<=length);uint32_t n=u32(data+at);at+=4;
                assert(n<=length-at);at+=n;
            }
        }
    }
    return 0;
}
static void tick(void) { const struct timespec delay={0,1000000};nanosleep(&delay,NULL); }
static void wait_marker(int which) {
    for(unsigned i=0;i<5000 && !leaf_tasks_probe(which);i++) tick();
    assert(leaf_tasks_probe(which)==1);
}
static void click(uint64_t owner,uint64_t mount,Binding b) {
    assert(b.button);
    assert(leaf_android_event(owner,mount,b.session,b.mount,b.button,1,b.revision,1,0)==0);
    assert(leaf_android_phase(owner,mount,3)==0);
}
int main(void) {
    NimMain();
    Binding binding={0};
    LeafAndroidCallbacks callbacks={1,sizeof(callbacks),&binding,command};
    uint64_t owner=0,mount=0;
    assert(leaf_android_create(&callbacks,&owner)==0);
    assert(leaf_android_attach(owner,400,600,1,&mount)==0);
    assert(leaf_android_phase(owner,mount,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0);
    click(owner,mount,binding);wait_marker(4);
    assert(leaf_tasks_probe(7)==1 && leaf_tasks_probe(2)==0);
    assert(leaf_android_phase(owner,mount,2)==0);
    assert(leaf_tasks_probe(10)==1);wait_marker(5);
    assert(leaf_android_phase(owner,mount,3)==5 && leaf_tasks_probe(2)==0);
    assert(leaf_android_phase(owner,mount,4)==0);
    uint64_t next=0;
    assert(leaf_android_attach(owner,600,400,1,&next)==0 && next>mount);
    assert(leaf_android_phase(owner,next,1)==0);
    for(unsigned i=0;i<5000 && leaf_tasks_probe(2)==0;i++) {
        assert(leaf_android_phase(owner,next,3)==0);tick();
    }
    assert(leaf_tasks_probe(2)==1 && leaf_tasks_probe(6)==1 && leaf_tasks_probe(8)==1);
    assert(leaf_tasks_probe(0)==1 && leaf_tasks_probe(1)==1);
    click(owner,next,binding);wait_marker(9);
    assert(leaf_android_close(owner)==0);wait_marker(11);
    assert(leaf_tasks_probe(3)==1 && leaf_tasks_probe(2)==1 && leaf_tasks_probe(12)==0);
    puts("Android retained tasks C ABI: passed (pause, remount, result, cancel)");
    return 0;
}
