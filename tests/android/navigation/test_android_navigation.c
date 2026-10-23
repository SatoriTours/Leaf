#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "leaf_android.h"
extern void NimMain(void);
extern int leaf_navigation_probe(int);
_Static_assert(sizeof(LeafAndroidBackFact)==96,"fixed-width back ABI");
_Static_assert(offsetof(LeafAndroidBackFact,depth)==88,"back ABI depth offset");
typedef struct Native {
    uint64_t owner,activity,session,mount,revision,push,increment,sequence,request;
    LeafAndroidBackFact nav;
    uint8_t *staged;size_t length;
    unsigned applies,replays;int fail;
} Native;
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const uint8_t *p) {return u32(p)|((uint64_t)u32(p+4)<<32);}
static void need(size_t at,size_t n,size_t length) {assert(at<=length && n<=length-at);}
static int string(const uint8_t *d,size_t length,size_t *at,const char *expected) {
    need(*at,4,length);uint32_t n=u32(d+*at);*at+=4;need(*at,n,length);
    int equal=expected && strlen(expected)==n && memcmp(d+*at,expected,n)==0;
    *at+=n;return equal;
}
static void frame(Native *n,const uint8_t *d,size_t length,int install) {
    need(0,36,length);uint32_t magic=u32(d);
    assert(magic==0x3156414c || magic==0x3556414c);
    unsigned version=(magic>>24)-'0';size_t at=36;
    if(u64(d+4) && install) {
        n->session=u64(d+4);n->mount=u64(d+12);
        if(u64(d+20))n->revision=u64(d+20);
    }
    for(unsigned i=0;i<u32(d+28);i++) {
        need(at,36,length);unsigned tag=u32(d+at),kind=u32(d+at+24);
        uint64_t handle=u64(d+at+4);at+=36;
        string(d,length,&at,NULL);int push=string(d,length,&at,"打开下一页");
        if(install && push && tag<2)n->push=handle;
        if(version>=2) {string(d,length,&at,NULL);string(d,length,&at,NULL);}
        if(version>=3) {need(at,12,length);at+=12;}
        if(version>=4) {
            need(at,8,length);assert(u32(d+at)==0 && u32(d+at+4)==0);at+=8;
        }
        if(version>=5) {
            need(at,8,length);unsigned back=u32(d+at),has=u32(d+at+4);at+=8;
            assert(back<=1 && has<=1);
            if(has) {
                need(at,44,length);assert(kind==12 && back==1);
                if(install) {
                    n->nav=(LeafAndroidBackFact){.handle=handle,.binding=u64(d+at+36),
                        .router=u64(d+at),.history=u64(d+at+8),.current=u64(d+at+16),
                        .previous=u64(d+at+24),.depth=u32(d+at+32)};
                }
                at+=44;
            }
        }
    }
    need(at,(size_t)u32(d+32)*72,length);at+=(size_t)u32(d+32)*72;
    if(version>=2) {need(at,4,length);assert(u32(d+at)==0);at+=4;}
    if(version>=4) {need(at,4,length);assert(u32(d+at)==0);at+=4;}
    assert(at==length);
}
static int32_t command(void *context,uint32_t tag,const uint8_t *d,size_t length,
                       double w,double h,double *measured) {
    Native *n=context;(void)h;
    switch(tag) {
    case 1:measured[0]=w;measured[1]=48;break;
    case 2:
        free(n->staged);n->staged=malloc(length);assert(n->staged);
        memcpy(n->staged,d,length);n->length=length;frame(n,d,length,0);break;
    case 3:
        n->applies++;frame(n,n->staged,n->length,1);
        if(n->fail) {n->fail=0;return 1234;}break;
    case 4:free(n->staged);n->staged=NULL;break;
    case 5:n->replays++;frame(n,d,length,1);break;
    case 6:frame(n,d,length,1);n->sequence=0;break;
    case 7:free(n->staged);n->staged=NULL;break;
    case 8:case 9:case 10:break;
    default:return 1;
    }
    return 0;
}
static void turn(Native *n) {assert(leaf_android_phase(n->owner,n->activity,3)==0);}
static void push(Native *n) {
    int depth=leaf_navigation_probe(2);
    assert(leaf_android_event(n->owner,n->activity,n->session,n->mount,n->push,++n->sequence,n->revision,1,0)==0);
    turn(n);assert(leaf_navigation_probe(2)==depth+1 && n->nav.depth==(unsigned)depth+1);
}
static LeafAndroidBackFact begin(Native *n) {
    LeafAndroidBackFact f=n->nav;f.session=n->session;f.mount=n->mount;f.revision=n->revision;
    f.sequence=++n->sequence;f.request=++n->request;f.phase=0;
    assert(leaf_android_back(n->owner,n->activity,&f)==0);return f;
}
static int32_t fact(Native *n,LeafAndroidBackFact *f,unsigned phase) {
    f->sequence=++n->sequence;f->phase=phase;
    return leaf_android_back(n->owner,n->activity,f);
}
int main(void) {
    NimMain();Native n={0};LeafAndroidCallbacks cb={5,sizeof(cb),&n,command};
    assert(leaf_android_create(&cb,&n.owner)==0);
    assert(leaf_android_attach(n.owner,400,600,1,&n.activity)==0);
    assert(n.nav.depth==1 && leaf_navigation_probe(2)==1);
    LeafAndroidBackFact root=n.nav;
    assert(leaf_android_back(n.owner,n.activity,&root)==5);
    assert(leaf_android_phase(n.owner,n.activity,1)==0);
    assert(leaf_android_back(n.owner,n.activity,NULL)==5);
    push(&n);
    LeafAndroidBackFact b=begin(&n),bad=b;
    bad.phase=3;assert(leaf_android_back(n.owner,n.activity,&bad)==5);
    bad=b;bad.session++;assert(leaf_android_back(n.owner,n.activity,&bad)==5);
    bad=b;bad.binding++;assert(leaf_android_back(n.owner,n.activity,&bad)==5);
    assert(fact(&n,&b,1)==0);turn(&n);assert(n.nav.depth==2);
    assert(fact(&n,&b,2)==5);
    b=begin(&n);unsigned applies=n.applies;
    assert(fact(&n,&b,2)==0 && n.applies==applies && leaf_navigation_probe(2)==2);
    assert(fact(&n,&b,2)==5);turn(&n);assert(n.nav.depth==1 && leaf_navigation_probe(2)==1);
    push(&n);b=begin(&n);push(&n);
    assert(fact(&n,&b,2)==5);turn(&n);assert(n.nav.depth==3);
    b=begin(&n);assert(leaf_android_phase(n.owner,n.activity,2)==0);
    assert(fact(&n,&b,2)==5 && leaf_android_phase(n.owner,n.activity,3)==5);
    assert(leaf_android_phase(n.owner,n.activity,1)==0 && fact(&n,&b,1)==0);
    turn(&n);assert(n.nav.depth==3);
    b=begin(&n);assert(fact(&n,&b,2)==0);n.fail=1;turn(&n);
    assert(n.replays==1 && n.nav.depth==3 && leaf_navigation_probe(2)==3);
    turn(&n);assert(n.nav.depth==3);assert(fact(&n,&b,2)==5);
    b=begin(&n);assert(fact(&n,&b,2)==0);turn(&n);assert(n.nav.depth==2);
    b=begin(&n);uint64_t oldActivity=n.activity;
    assert(leaf_android_phase(n.owner,n.activity,4)==0);
    n.activity=0;assert(leaf_android_attach(n.owner,600,400,1,&n.activity)==0);
    assert(n.activity>oldActivity && leaf_android_phase(n.owner,n.activity,1)==0);
    assert(leaf_navigation_probe(0)==1 && n.nav.depth==2);
    assert(fact(&n,&b,2)==5);
    b=begin(&n);assert(fact(&n,&b,2)==0);turn(&n);assert(n.nav.depth==1);
    assert(leaf_android_close(n.owner)==0 && leaf_navigation_probe(1)==1);
    puts("Android typed navigation C ABI: passed");return 0;
}
