## Private Win32 native-resource carrier: stable groups with exactly one
## authoritative entry per native window.
##
## Not re-exported from leaf's public API. The backend keeps these objects as
## refs (never as deep copies): the group is the ownership identity and every
## entry is the per-window authority for `HWND`/native parent/subclass
## cookie+callback/lifecycle phase. Native calls still happen in the backend;
## this module only stores the state transitions that must be impossible to
## fail once a native credential (successful BOOL or NCDESTROY) has been seen.
import ../../backend      # NodeHandle

type
  EntryPhase* = enum
    ## The window is live and this entry is authoritative for it.
    epOwned
    ## The subclass identity was removed successfully (routing stopped); the
    ## window is still owned.
    epSubclassRemoved
    ## The window ended: a successful DestroyWindow BOOL or an irreversible
    ## NCDESTROY. Nothing may release it again.
    epEnded

  GroupPhase* = enum
    ## Published and being parked (owned, not yet reusable).
    gpParking
    ## Hidden and reusable by the same owner + signature.
    gpParked
    ## A parked group currently re-keyed for a candidate row.
    gpBorrowing
    ## A failed group: still owned, enumerable, never reusable.
    gpFailed

  ResEntry* = ref object
    ## Per-window authority. The same ref is held by the control, the group and
    ## every work set; it is never copied into another authority.
    window*: pointer           ## native window identity (HWND value)
    parent*: pointer           ## native parent identity
    handle*: NodeHandle
    cookie*: uint
    callback*: uint64
    subclassed*: bool
    phase*: EntryPhase
    token*: uint64             ## stable typed-binding token (0 = no binding)

  ResGroup* = ref object
    ## Ownership identity of one native subtree (or one solo parked row).
    owner*: uint64
    signature*: string
    root*: pointer
    phase*: GroupPhase
    entries*: seq[ResEntry]
    primary*: ref CatchableError
    secondary*: ref CatchableError
    published*: bool

  ResRegistry* = object
    groups*: seq[ResGroup]

proc newEntry*(window: pointer, parent: pointer, handle: NodeHandle, cookie: uint,
               callback: uint64, subclassed: bool, token = 0'u64): ResEntry =
  ## Fail-able preparation only: called while the window is still owned by its
  ## previous owner (a control or a prepared creation view). The carrier keeps
  ## only native resource state; the typed control lives in the backend store.
  ResEntry(window: window, parent: parent, handle: handle, cookie: cookie,
    callback: callback, subclassed: subclassed, token: token)

proc setEntryWindow*(entry: ResEntry, window: pointer, parent: pointer) =
  ## Scalar update used by creation before the entry is published.
  if entry == nil: return
  entry.window = window
  entry.parent = parent

proc newGroup*(owner: uint64, signature: string): ResGroup =
  ## Fail-able preparation only; nothing is published yet.
  ResGroup(owner: owner, signature: signature)

proc attachEntry*(group: ResGroup, entry: ResEntry) =
  ## Keep the *same* per-window authority in the group (no deep copy).
  ## Fail-able while preparing; must run before `publishOwner`.
  group.entries.add(entry)

proc entryCount*(group: ResGroup): int =
  if group == nil: 0 else: group.entries.len

proc outstanding*(group: ResGroup): int =
  ## Entries that still own a live window.
  if group == nil: return 0
  for entry in group.entries:
    if entry.phase != epEnded: inc result

proc allEnded*(group: ResGroup): bool =
  group != nil and group.entries.len > 0 and group.outstanding == 0

proc reservePublish*(registry: var ResRegistry) =
  ## Grow the registry before a non-failing publish: only the outer seq grows,
  ## and it happens before any ownership change.
  let base = registry.groups.len
  registry.groups.add(nil)
  registry.groups.setLen(base)

proc publishOwner*(registry: var ResRegistry, group: ResGroup,
                   phase: GroupPhase): bool =
  ## The single ownership publish. Every allocation (entries, seq capacity) is
  ## done before this call: here only scalar/ref stores happen, so it cannot
  ## fail. It must run *before* the first cookie/control-table removal.
  if group == nil or group.published: return false
  group.phase = phase
  group.published = true
  registry.groups.add(group)
  true

proc noteSubclassInstalled*(entry: ResEntry, cookie: uint, callback: uint64) =
  ## First step after a successful SetWindowSubclass BOOL.
  if entry == nil: return
  entry.cookie = cookie
  entry.callback = callback
  entry.subclassed = true
  entry.phase = epOwned

proc noteSubclassRemoved*(entry: ResEntry) =
  ## First step after a successful RemoveWindowSubclass BOOL: scalar and
  ## idempotent, so no later failure can lose it.
  if entry == nil: return
  entry.subclassed = false
  if entry.phase != epEnded: entry.phase = epSubclassRemoved

proc noteWindowEnded*(entry: ResEntry) =
  ## First step after a successful DestroyWindow BOOL or an irreversible
  ## NCDESTROY: scalar, unfailable, idempotent.
  if entry == nil: return
  entry.phase = epEnded
  entry.subclassed = false

proc liveGroups*(registry: ResRegistry): int =
  ## The global budget counts every group that still owns windows.
  registry.groups.len

proc takeParked*(registry: var ResRegistry, owner: uint64,
                 signature: string): ResGroup =
  ## Claim the first reusable group of this owner+signature. Phase change only:
  ## no allocation, no deep copy.
  for group in registry.groups:
    if group.phase == gpParked and group.owner == owner and
        group.signature == signature:
      group.phase = gpBorrowing
      return group
  nil

proc removeGroup*(registry: var ResRegistry, group: ResGroup): bool =
  ## Non-failing bookkeeping: drop a group whose entries all ended (or whose
  ## ownership was handed over to its controls).
  for index in 0 ..< registry.groups.len:
    if registry.groups[index] == group:
      registry.groups.delete(index)
      return true
  false
