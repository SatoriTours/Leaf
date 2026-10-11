/* Test-only: compile against actual Windows SDK headers; no product C shim. */
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <imm.h>
#include <stddef.h>
#define LEAF_SIZE(n, w) _Static_assert(sizeof(n) == sizeof(w), "size: " #w)
#define LEAF_ALIGN(n, w) _Static_assert(_Alignof(n) == _Alignof(w), "alignment: " #w)
#define LEAF_FIELD(n, w, f) _Static_assert(offsetof(n, f) == offsetof(w, f), "offset: " #w "." #f)
