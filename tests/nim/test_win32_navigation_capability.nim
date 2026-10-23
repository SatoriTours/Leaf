## Windows navigation contract; actual HWND/back-message coverage is separate.
import std/unittest
import leaf/[core, backend]
import leaf/backends/win32/capabilities

suite "Win32 typed navigation capability":
  test "a native navigation outlet is supported alongside the existing list":
    let caps = win32Capabilities()
    check NodeKind.navigation in caps.kinds
    check NodeKind.virtualList in caps.kinds
    check cfInputReset in caps.controls
