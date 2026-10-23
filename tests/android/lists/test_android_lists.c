#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "leaf_android.h"
extern void NimMain(void);
extern int leaf_lists_probe(int);
#ifndef LEAF_LISTS_VERSION_RED
extern int32_t leaf_android_scroll(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                                  uint64_t,uint64_t,uint64_t,double);
#endif
typedef struct Native {
    uint64_t owner,activity,session,mount,revision,list,source,button;
    uint8_t *staged; size_t length;
    double offset,total;
    unsigned first,finish,rows,creates,applies,replays,geometry_replays;
    int fail_apply,fail_replay,reenter,reenter_status,new_intent;
} Native;
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const uint8_t *p) {return u32(p)|((uint64_t)u32(p+4)<<32);}
static double number(const uint8_t *p) {uint64_t b=u64(p);double d;memcpy(&d,&b,8);return d;}
static void need(size_t at,size_t n,size_t length) {assert(at<=length && n<=length-at);}
static void string(const uint8_t *d,size_t length,size_t *at) {
    need(*at,4,length);uint32_t n=u32(d+*at);*at+=4;need(*at,n,length);*at+=n;
}
static void frame(Native *n,const uint8_t *d,size_t length,int install) {
    need(0,36,length);uint32_t magic=u32(d);assert(magic>=0x3156414c && magic<=0x3456414c);
    int v=magic>>24;v-='0';assert(v>=1 && v<=4);
    if(u64(d+4)) {n->session=u64(d+4);n->mount=u64(d+12);n->revision=u64(d+20);}
    size_t at=36;unsigned rows=0,creates=0;
    for(uint32_t i=0;i<u32(d+28);i++) {
        need(at,36,length);uint32_t op=u32(d+at),kind=u32(d+at+24);uint64_t handle=u64(d+at+4);at+=36;
        if(op==0) creates++;
        if(kind==3 && op!=3)n->button=handle;
        string(d,length,&at);string(d,length,&at);
        if(v>=2) {string(d,length,&at);string(d,length,&at);}
        if(v>=3) {need(at,12,length);at+=12;}
        if(v>=4) {
            need(at,4,length);unsigned has=u32(d+at);at+=4;assert(has<=1);
            if(has) {
                need(at,36,length);assert(kind==11);
                n->list=handle;n->source=u64(d+at);assert(u32(d+at+8)==100000);at+=36;
            }
            need(at,4,length);has=u32(d+at);at+=4;assert(has<=1);
            if(has) {
                need(at,20,length);assert(u64(d+at)==n->list && u64(d+at+8)==n->source);
                assert(u32(d+at+16)<100000);at+=20;string(d,length,&at);rows++;
            }
        }
    }
    need(at,(size_t)u32(d+32)*72,length);at+=(size_t)u32(d+32)*72;
    if(v>=2) {
        need(at,4,length);unsigned writes=u32(d+at);at+=4;
        for(unsigned i=0;i<writes;i++) {
            need(at,20,length);unsigned effects=u32(d+at+16);at+=20;
            for(unsigned j=0;j<effects;j++) {need(at,4,length);at+=4;string(d,length,&at);need(at,16,length);at+=16;}
        }
    }
    if(v>=4) {
        need(at,4,length);unsigned count=u32(d+at);at+=4;
        for(unsigned i=0;i<count;i++) {
            need(at,60,length);assert(u64(d+at)==n->list && u64(d+at+8)==n->source);
            if(install) {
                n->offset=number(d+at+24);n->total=number(d+at+32);
                n->first=u32(d+at+48);n->finish=u32(d+at+52);
            }
            unsigned protect=u32(d+at+56);at+=60;need(at,(size_t)protect*4,length);at+=(size_t)protect*4;
        }
    }
    assert(at==length);
    if(install && u32(d+28)) {n->rows=rows;n->creates+=creates;}
}
static int32_t command(void *context,uint32_t tag,const uint8_t *data,size_t length,
                       double w,double h,double *measured) {
    Native *n=context;(void)h;
    switch(tag) {
    case 1:measured[0]=w;measured[1]=24;break;
    case 2:
        free(n->staged);n->staged=malloc(length);assert(n->staged);
        memcpy(n->staged,data,length);n->length=length;frame(n,data,length,0);break;
    case 3:
        n->applies++;frame(n,n->staged,n->length,1);
#ifndef LEAF_LISTS_VERSION_RED
        if(n->reenter) {
            n->reenter_status=leaf_android_phase(n->owner,n->activity,3);
            assert(leaf_android_close(n->owner)==5); /* active native turn owns the cleanup frame */
        }
        if(n->new_intent && u32(n->staged+28)==0) {
            n->new_intent=0;
            assert(leaf_android_scroll(n->owner,n->activity,n->session,n->mount,n->list,100,n->revision,n->source,120)==0);
        }
#endif
        if(n->fail_apply && u32(n->staged+28)==0)return 1234;
        break;
    case 4:free(n->staged);n->staged=NULL;break;
    case 5:n->replays++;frame(n,data,length,1);break;
    case 6:frame(n,data,length,0);break;
    case 7:free(n->staged);n->staged=NULL;break;
    case 8:case 9:case 10:break;
    case 12:n->geometry_replays++;if(n->fail_replay)return 8765;frame(n,data,length,1);break;
    default:return 1;
    }
    return 0;
}
#ifndef LEAF_LISTS_VERSION_RED
static int32_t scroll(Native *n,uint64_t seq,double offset) {
    return leaf_android_scroll(n->owner,n->activity,n->session,n->mount,n->list,seq,n->revision,n->source,offset);
}
static void turn(Native *n) {assert(leaf_android_phase(n->owner,n->activity,3)==0);}
#endif
int main(void) {
    NimMain();Native n={0};LeafAndroidCallbacks cb={4,sizeof(cb),&n,command};
    int32_t status=leaf_android_create(&cb,&n.owner);
    if(status!=0) {printf("ABI4 create rejected: status=%d expected=0\n",status);return 1;}
#ifndef LEAF_LISTS_VERSION_RED
    assert(leaf_android_attach(n.owner,300,192,1,&n.activity)==0);
    assert(n.list && n.source && n.total==4800000 && !n.rows && leaf_lists_probe(3)==0);
    assert(scroll(&n,1,24)==5);
    assert(leaf_android_phase(n.owner,n.activity,1)==0);
    turn(&n);assert(leaf_lists_probe(3)==0); /* fact queued, no synchronous business */
    turn(&n);assert(leaf_lists_probe(3)==5 && leaf_lists_probe(2)==1);
    assert(n.length<16384 && n.total==4800000);
    uint64_t revision=n.revision,mount=n.mount;unsigned creates=n.creates,applies=n.applies;
    assert(leaf_android_scroll(n.owner,n.activity,n.session+1,n.mount,n.list,1,n.revision,n.source,24)==5);
    assert(leaf_android_scroll(n.owner,n.activity,n.session,n.mount,n.list,1,n.revision+1,n.source,24)==5);
    assert(leaf_android_scroll(n.owner,n.activity,n.session,n.mount,n.list,1,n.revision,n.source+1,24)==5);
    assert(scroll(&n,1,NAN)==5 && scroll(&n,1,INFINITY)==5 && scroll(&n,0,24)==5);
    assert(scroll(&n,1,24)==0 && scroll(&n,1,48)==5);
    assert(n.applies==applies && n.offset==0 && leaf_lists_probe(3)==5);
    n.reenter=1;turn(&n);n.reenter=0;
    assert(n.reenter_status==5 && n.offset==24 && n.revision==revision && n.creates==creates);
    turn(&n);assert(leaf_lists_probe(2)==1 && n.length<16384);
    assert(leaf_android_event(n.owner,n.activity,n.session,n.mount,n.button,2,n.revision,1,0)==0);
    turn(&n);assert(leaf_lists_probe(4)==1);
    assert(leaf_android_phase(n.owner,n.activity,2)==0 && scroll(&n,3,48)==5);
    assert(leaf_android_phase(n.owner,n.activity,3)==5);
    assert(leaf_android_phase(n.owner,n.activity,1)==0);
    assert(scroll(&n,3,48)==0);n.fail_apply=1;
    assert(leaf_android_phase(n.owner,n.activity,3)==6);
    assert(n.offset==24 && n.mount==mount && n.geometry_replays==1 && n.replays==0);
    n.fail_apply=0;applies=n.applies;turn(&n);assert(n.applies==applies);
    assert(scroll(&n,4,48)==0);turn(&n);assert(n.offset==48);
    turn(&n); /* finish the previously queued row fact before geometry injection */
    assert(scroll(&n,5,72)==0);n.fail_apply=1;n.new_intent=1;
    status=leaf_android_phase(n.owner,n.activity,3);
    printf("failure-during status=%d offset=%.0f mount=%llu geometry_replays=%u\n",status,n.offset,
        (unsigned long long)n.mount,n.geometry_replays);fflush(stdout);
    assert(status==6 && n.offset==48);
    n.fail_apply=0;turn(&n);assert(n.offset==120);
    turn(&n);
    assert(scroll(&n,101,144)==0);n.fail_apply=1;n.fail_replay=1;
    assert(leaf_android_phase(n.owner,n.activity,3)==6);
    assert(scroll(&n,102,168)==5 && leaf_android_phase(n.owner,n.activity,3)==5);
    assert(leaf_android_close(n.owner)==0 && leaf_lists_probe(5)==1);
    assert(leaf_android_create(&cb,&n.owner)==1); /* dirty ID is never overwritten */
    puts("Android retained lists C ABI: passed");
#else
    assert(leaf_android_close(n.owner)==0);
#endif
    return 0;
}
