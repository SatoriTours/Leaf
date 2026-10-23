#ifndef LEAF_NATIVE_H
#define LEAF_NATIVE_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Additive native-platform ABI. No Node, closure, JNI reference or Nim string
 * crosses it. Initialize Nim once on the platform UI thread before calling.
 * Functions return status values; no catchable Nim exception crosses C. */
enum {
    LEAF_NATIVE_OK = 0,
    LEAF_NATIVE_INVALID_ARGUMENT = 1,
    LEAF_NATIVE_INVALID_UTF8 = 2,
    LEAF_NATIVE_LIMIT = 3,
    LEAF_NATIVE_NO_MEMORY = 4
};

typedef struct LeafNativeBytes {
    uint8_t *data;
    size_t length;
} LeafNativeBytes;

/* input is borrowed for this call only; NULL is valid iff length == 0.
 * output must point to a zero-initialized owning slot. Success makes a new
 * owned copy; empty success stays {NULL,0}. Failure leaves output unchanged.
 * UTF-8 encodes Unicode scalar values, including U+0000. No terminator is
 * appended or counted. The existing Leaf MaxStringBytes (1 MiB) applies.
 * Pointers must address their stated storage; arbitrary addresses are invalid.
 * Never copy a nonempty owning slot: release its original slot exactly once. */
int32_t leaf_native_utf8_copy(const uint8_t *input, size_t length,
                              LeafNativeBytes *output);

/* Clears the owning slot before freeing its memory. NULL and an already
 * cleared slot are allowed. Use this, never free/delete a returned buffer. */
void leaf_native_bytes_release(LeafNativeBytes *value);

#ifdef __cplusplus
}
#endif
#endif
