## Internal pure message classification. It owns no HWND, history or callback.
import ../../core

const
  BackSysKeyDown* = 0x0104'u32
  BackAppCommand* = 0x0319'u32

type NavigationInput* = enum
  noNavigationInput, backKey, repeatedBackKey, backCommand

proc navigationInput*(message: uint32, key: uint, detail: int): NavigationInput =
  if message == BackSysKeyDown and key == 0x25 and
      (detail and (1 shl 29)) != 0:
    if (detail and (1 shl 30)) != 0: repeatedBackKey else: backKey
  elif message == BackAppCommand and ((detail shr 16) and 0x0fff) == 1:
    backCommand
  else: noNavigationInput

proc advanceBackRequest*(counter: var uint64): uint64 =
  if counter == high(uint64): fail("native navigation request identity exhausted")
  inc counter
  counter
