## Pure example state; saving records an in-memory snapshot, not persistence.
import std/strutils

type
  EditMode* = enum echoValue, rejectValue, trimValue
  FormModel* = object
    name*: string
    notifications*: bool
    count*: int
    reset*: uint64
    mode*: EditMode
    conflictMode*, invalidCandidate*: bool
    attempted*, hasSaved*: bool
    savedName*: string
    savedNotifications*: bool

proc nameInvalid*(m: FormModel): bool = m.attempted and m.name.strip.len == 0

proc formDirty*(m: FormModel): bool =
  not m.hasSaved or m.name != m.savedName or m.notifications != m.savedNotifications

proc saveForm*(m: FormModel): FormModel =
  result = m
  result.attempted = true
  if result.nameInvalid: return
  inc result.count
  result.hasSaved = true
  result.savedName = result.name
  result.savedNotifications = result.notifications
