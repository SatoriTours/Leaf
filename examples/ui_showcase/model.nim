## In-memory settings only. No persistence, file writes, or network access.
import std/[strutils, unicode]

type SettingsModel* = object
  name*, savedName*: string
  bio*, savedBio*: string
  attempted*: bool
  saveCount*: int
  reset*: uint64

proc dirty*(m: SettingsModel): bool = m.name != m.savedName or m.bio != m.savedBio
proc nameInvalid*(m: SettingsModel): bool = m.attempted and strutils.strip(m.name).len == 0

proc bioInvalid*(m: SettingsModel): bool = m.attempted and m.bio.runeLen > 160

proc editBio*(m: SettingsModel, value: string): SettingsModel =
  result=m
  result.bio=value.replace("\r\n", "\n").replace("\r", "\n")

proc editName*(m: SettingsModel, value: string): SettingsModel =
  result=m
  result.name=value

proc saveSettings*(m: SettingsModel): SettingsModel =
  result=m
  result.attempted=true
  if result.nameInvalid or result.bioInvalid: return
  result.savedName=result.name
  result.savedBio=result.bio
  inc result.saveCount

proc cancelSettings*(m: SettingsModel): SettingsModel =
  result=m
  result.name=result.savedName
  result.bio=result.savedBio
  result.attempted=false
  inc result.reset
