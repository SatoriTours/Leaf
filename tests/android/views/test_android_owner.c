/* Real C caller of the Nim owner ABI, not a Nim-to-Nim calling convention test. */
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include "leaf_android.h"
extern void NimMain(void);
_Static_assert(offsetof(LeafAndroidCallbacks,context)==8,"context ABI");
_Static_assert(offsetof(LeafAndroidCallbacks,command)==8+sizeof(void *),"command ABI");
_Static_assert(sizeof(LeafAndroidCallbacks)==8+2*sizeof(void *),"callback struct ABI");
static unsigned counts[8];
static int32_t native(void *context,uint32_t tag,const uint8_t *data,size_t length,
                      double width,double height,double *measured) {
    assert(context==counts && tag>=1 && tag<=7);
    ++counts[tag];
    if(tag==1 || tag==2 || tag==5 || tag==6) {
        assert(length>=36 && data && data[0]=='L' && data[1]=='A' && data[2]=='V' && data[3]=='1');
    }
    if(tag==1) { assert(width>=0 && height>=0 && measured);measured[0]=100;measured[1]=40; }
    return 0;
}
int main(void) {
    NimMain();
    LeafAndroidCallbacks callbacks={1,sizeof(callbacks),counts,native};
    uint64_t owner=0,mount=0;
    assert(leaf_android_create(&callbacks,&owner)==0 && owner);
    assert(leaf_android_attach(owner,400,600,1,&mount)==0 && mount);
    assert(leaf_android_phase(owner,mount,1)==0);
    assert(leaf_android_phase(owner,mount,3)==0);
    assert(leaf_android_phase(owner,mount,4)==0);
    assert(leaf_android_close(owner)==0);
    assert(leaf_android_close(owner)==5);
    assert(counts[1]>0 && counts[2]==1 && counts[3]==1 && counts[7]==1);
    puts("Android owner C ABI: passed");
    return 0;
}
