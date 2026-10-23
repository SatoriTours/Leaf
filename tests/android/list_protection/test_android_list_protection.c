/* Reuse the independent LAV1..4 reader/platform from the accepted non-input
 * fixture; this caller tests ABI protection facts, not Android focus or IME. */
#define main leaf_original_lists_main
#include "../lists/test_android_lists.c"
#undef main

extern int32_t leaf_android_protect(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                                   uint64_t,uint64_t,uint64_t,uint32_t);
static int32_t protect(Native *n,uint64_t handle,uint64_t seq,uint32_t reasons) {
    return leaf_android_protect(n->owner,n->activity,n->session,n->mount,handle,
                               seq,n->revision,1,reasons);
}
static uint32_t row_index(Native *n,uint64_t button) {
    size_t at=36;uint64_t parent=0,roots[16];uint32_t indexes[16];unsigned count=0;
    for(uint32_t i=0;i<u32(n->staged+28);i++) {
        const uint8_t *d=n->staged;need(at,36,n->length);
        uint64_t handle=u64(d+at+4);
        if(handle==button)parent=u64(d+at+12);
        at+=36;
        for(int j=0;j<4;j++)string(d,n->length,&at);
        need(at,16,n->length);at+=12;
        unsigned has=u32(d+at);at+=4;
        if(has) {need(at,36,n->length);at+=36;}
        need(at,4,n->length);has=u32(d+at);at+=4;
        if(has) {
            need(at,20,n->length);assert(count<16);
            roots[count]=handle;indexes[count++]=u32(d+at+16);
            at+=20;string(d,n->length,&at);
        }
    }
    for(unsigned i=0;i<count;i++)if(roots[i]==parent)return indexes[i];
    assert(!"Button must have a typed row parent");return 0;
}
int main(void) {
    NimMain();Native n={0};LeafAndroidCallbacks cb={4,sizeof(cb),&n,command};
    assert(leaf_android_create(&cb,&n.owner)==0);
    assert(leaf_android_attach(n.owner,300,192,1,&n.activity)==0);
    assert(leaf_android_phase(n.owner,n.activity,1)==0);
    turn(&n);turn(&n);
    assert(leaf_lists_probe(3)==5 && leaf_lists_probe(2)==1);
    uint64_t button=n.button;
    uint32_t index=row_index(&n,button);
    assert(scroll(&n,1,480)==0);turn(&n); /* The unprotected request is queued. */
    unsigned applies=n.applies,creates=n.creates;
    assert(leaf_android_protect(n.owner,n.activity,n.session+1,n.mount,button,100,n.revision,1,1)==5);
    assert(leaf_android_protect(n.owner,n.activity+1,n.session,n.mount,button,100,n.revision,1,1)==5);
    assert(leaf_android_protect(n.owner,n.activity,n.session,n.mount+1,button,100,n.revision,1,1)==5);
    assert(leaf_android_protect(n.owner,n.activity,n.session,n.mount,button,100,n.revision+1,1,1)==5);
    assert(leaf_android_protect(n.owner,n.activity,n.session,n.mount,button,100,n.revision,2,1)==5);
    assert(protect(&n,button,100,4)==5 && protect(&n,button,0,1)==5);
    assert(protect(&n,button,100,2)==5); /* Composition cannot belong to a Button. */
    assert(protect(&n,button,1,1)==0 && protect(&n,button,1,0)==5);
    assert(n.applies==applies && n.creates==creates); /* Recording is data-only. */
    turn(&n);turn(&n);
    assert(leaf_lists_probe(2)==1 && n.offset==480);
    assert(n.length>=8 && u32(n.staged+n.length-8)==1 && u32(n.staged+n.length-4)==index);
    assert(leaf_android_event(n.owner,n.activity,n.session,n.mount,button,2,n.revision,1,0)==0);
    turn(&n);assert(leaf_lists_probe(4)==1); /* Same accepted old Button survives. */
    assert(leaf_android_phase(n.owner,n.activity,2)==0);
    assert(protect(&n,button,100,0)==5 && leaf_android_phase(n.owner,n.activity,3)==5);
    assert(leaf_android_phase(n.owner,n.activity,1)==0);
    assert(protect(&n,button,2,0)==0); /* Paused invalid fact consumed no sequence. */
    turn(&n);turn(&n);
    assert(leaf_android_event(n.owner,n.activity,n.session,n.mount,button,3,n.revision,1,0)==5);
    assert(protect(&n,button,3,1)==5); /* Removed handles cannot pin replacements. */
    assert(leaf_android_close(n.owner)==0 && leaf_lists_probe(5)==1);
    puts("Android protected row facts C ABI: passed");
    return 0;
}
