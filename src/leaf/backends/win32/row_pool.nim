## Bounded native row parking. A list row is a compound native subtree; when it
## scrolls out of the viewport the windows may be hidden and kept for a future
## row with the *same* structural signature instead of being destroyed.
##
## This module owns only raw native identity (HWND + structural signature) and
## the bound. Placement, transient/IME/selection reset, cookie/subclass/command
## re-issue and every failure owner stay with the backend that created them.
import std/[algorithm, strutils]
import ../../core
import ./api

const
  MaxParkedRows* = 8
    ## Bound on rows parked outside the accepted frame. The pool is an
    ## optimisation with an owner, never an unbounded cache of every row ever
    ## scrolled past.

type
  RowSlot* = object
    ## One parked native subtree root. `signature` is derived from the accepted
    ## entity subtree (kinds + parent/child topology) so a reused slot is only
    ## ever handed a structurally compatible row.
    signature*: string
    root*: HWND
    windows*: seq[HWND]
      ## Pre-order windows of the parked subtree; index 0 is `root`.
    parents*: seq[int]
      ## `parents[i]` is the index of window i's parent inside `windows`
      ## (-1 for the root), so re-attachment keeps the exact topology.
    owner*: uint64
      ## Owning list handle as raw identity (the pool stays free of the Backend
      ## module types). A slot is only handed back to the same list, so source
      ## identity never crosses viewports and no re-parenting is needed.

  RowPool* = object
    slots*: seq[RowSlot]
    parked*, reused*, destroyed*: int

proc rowSignature*(kinds: openArray[NodeKind],
                   parents: openArray[int]): string =
  ## Structural signature of a row subtree: node kinds in pre-order *and* the
  ## parent index of every node. Two rows with the same kind sequence but a
  ## different parent/child topology are not interchangeable.
  if kinds.len != parents.len: return ""
  result = newStringOfCap(kinds.len * 6)
  for kind in kinds:
    result.add(char(ord(kind) + 1))
  result.add('|')
  for index, parent in parents:
    if index > 0: result.add(',')
    result.add($parent)

proc len*(pool: RowPool): int = pool.slots.len

proc clearOwner*(pool: var RowPool, owner: uint64): seq[RowSlot] =
  ## Hand back the slots of a list that is going away (removed/source swapped/
  ## restored/closed) so the caller destroys them with an explicit owner.
  var keep: seq[RowSlot]
  for index in 0 ..< pool.slots.len:
    if pool.slots[index].owner == owner: result.add(pool.slots[index])
    else: keep.add(pool.slots[index])
  pool.slots = keep

proc take*(pool: var RowPool, owner: uint64, signature: string,
           slot: var RowSlot): bool =
  ## Claim exactly one compatible parked slot and move its ownership out of the
  ## pool in a single step. A caller never needs a second lookup or removal, so
  ## a single slot cannot be lost and a later slot cannot be taken by mistake.
  if signature.len == 0: return false
  for index in 0 ..< pool.slots.len:
    if pool.slots[index].owner == owner and pool.slots[index].signature == signature:
      slot = pool.slots[index]
      pool.slots.delete(index)
      inc pool.reused
      return true
  false

proc peek*(pool: RowPool, signature: string): int =
  for index in 0 ..< pool.slots.len:
    if pool.slots[index].signature == signature: return index
  -1

proc hasRoom*(pool: RowPool): bool = pool.slots.len < MaxParkedRows

proc reserve*(pool: var RowPool, extra: int) =
  ## Grow the reusable slot store before an ownership move needs it, so the
  ## `park` step itself has no allocation left to fail on.
  if extra <= 0: return
  let base = pool.slots.len
  for _ in 0 ..< extra: pool.slots.add(RowSlot(root: nil))
  pool.slots.setLen(base)

proc park*(pool: var RowPool, slot: RowSlot): bool =
  ## Keep a parked slot only while the pool is bounded; the caller destroys the
  ## windows it cannot park.
  if not pool.hasRoom(): return false
  pool.slots.add(slot)
  true

proc clear*(pool: var RowPool): seq[RowSlot] =
  ## Hand every parked slot back to the caller so its owner can destroy the
  ## windows in a single explicit cleanup step.
  result = pool.slots
  pool.slots.setLen(0)
