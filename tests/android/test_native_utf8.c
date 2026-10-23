/* Runs against the real Nim C ABI, including ownership and malformed bytes. */
#include "leaf_native.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void NimMain(void);
_Static_assert(sizeof(((LeafNativeBytes *)0)->length) == sizeof(size_t), "size ABI");

int main(void) {
    NimMain();
    LeafNativeBytes out = {0};
    uint8_t input[] = {0xe4, 0xb8, 0xad, 0, 0xf0, 0x9f, 0x98, 0x80, 0x61};
    assert(leaf_native_utf8_copy(input, sizeof input, &out) == LEAF_NATIVE_OK);
    assert(out.data != input && out.length == sizeof input);
    assert(memcmp(out.data, input, sizeof input) == 0);
    input[0] = 'x';
    assert(out.data[0] == 0xe4); /* An owned copy, not a borrowed pointer. */
    uint8_t *owned = out.data;
    assert(leaf_native_utf8_copy(NULL, 0, &out) == LEAF_NATIVE_INVALID_ARGUMENT);
    assert(out.data == owned && out.length == sizeof input);
    leaf_native_bytes_release(&out);
    assert(out.data == NULL && out.length == 0);
    leaf_native_bytes_release(&out);
    leaf_native_bytes_release(NULL);
    assert(leaf_native_utf8_copy(NULL, 0, &out) == LEAF_NATIVE_OK);
    assert(out.data == NULL && out.length == 0);
    assert(leaf_native_utf8_copy(NULL, 1, &out) == LEAF_NATIVE_INVALID_ARGUMENT);
    assert(leaf_native_utf8_copy(input, 1, NULL) == LEAF_NATIVE_INVALID_ARGUMENT);
    /* Must enforce the limit before touching an inaccessible address. */
    assert(leaf_native_utf8_copy((void *)1, SIZE_MAX, &out) == LEAF_NATIVE_LIMIT);
    const uint8_t invalid[][4] = {
        {0x80}, {0xc0,0x80}, {0xc1,0xbf}, {0xc2,0},
        {0xe0,0x9f,0x80}, {0xed,0xa0,0x80}, {0xf0,0x8f,0xbf,0xbf},
        {0xf4,0x90,0x80,0x80}, {0xf5,0x80,0x80,0x80}, {0xff}
    };
    const size_t lengths[] = {1,2,2,2,3,3,4,4,4,1};
    for (size_t i = 0; i < sizeof lengths / sizeof *lengths; ++i) {
        assert(leaf_native_utf8_copy(invalid[i], lengths[i], &out) == LEAF_NATIVE_INVALID_UTF8);
        assert(out.data == NULL && out.length == 0);
    }
    const uint8_t valid[] = {0,0x7f,0xc2,0x80,0xdf,0xbf,0xe0,0xa0,0x80,
        0xed,0x9f,0xbf,0xee,0x80,0x80,0xef,0xbf,0xbf,0xf0,0x90,0x80,0x80,
        0xf4,0x8f,0xbf,0xbf};
    assert(leaf_native_utf8_copy(valid, sizeof valid, &out) == LEAF_NATIVE_OK);
    assert(out.length == sizeof valid && memcmp(out.data, valid, sizeof valid) == 0);
    leaf_native_bytes_release(&out);
    for (size_t n = 1; n < 4; ++n) {
        const uint8_t four[] = {0xf0,0x90,0x80,0x80};
        assert(leaf_native_utf8_copy(four, n, &out) == LEAF_NATIVE_INVALID_UTF8);
    }
    puts("native_utf8 C ABI: passed");
    return 0;
}
