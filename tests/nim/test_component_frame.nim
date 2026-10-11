import std/[unittest,os]
import leaf/gpui_ffi_v2
{.passC:"-I" & currentSourcePath().parentDir.parentDir.parentDir & "/include".}
{.emit:"""
#include "leaf_gpui_v2.h"
_Static_assert(sizeof(LeafFrameSample)==40,"FRAME payload size");
_Static_assert(_Alignof(LeafFrameSample)==8,"FRAME payload align");
_Static_assert(offsetof(LeafFrameSample,host_renders)==32,"FRAME count offset");
""".}
suite "optional typed frame payload":
  test "C and Nim use the same borrowed fixed-width payload":
    check sizeof(LeafFrameSample)==40
    check alignof(LeafFrameSample)==8
    check offsetOf(LeafFrameSample,host_renders)==32
