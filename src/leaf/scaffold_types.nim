## Command and naming contracts shared by scaffold plans and templates.
import std/[strutils, sets]
import ./[core, project]

type
  ScaffoldOptions* = object
    target*, project*: string
    fields*: seq[string]
    dryRun*: bool
  FieldSpec* = object
    name*, kind*: string
  ResourceSpec* = object
    model*, singular*, plural*: string
    fields*: seq[FieldSpec]
    migration*: int
  ScaffoldManifest* = object
    schema*: int
    resources*: seq[ResourceSpec]
  ScaffoldFile* = object
    path*, content*: string
    update*: bool
    previous*: string

const Keywords = "addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type using var when while xor yield result"

proc identity*(name: string): string = name.replace("_", "").toLowerAscii()

proc checkIdentifier*(name: string) =
  if name.len == 0 or not name[0].isAlphaAscii or name.endsWith("_") or "__" in name:
    fail("invalid Nim identifier: " & name)
  for c in name:
    if not (c.isAlphaAscii or c in {'0'..'9', '_'}): fail("invalid Nim identifier: " & name)
  if identity(name) in Keywords.splitWhitespace(): fail("reserved Nim identifier: " & name)

proc snake(name: string): string =
  for i, c in name:
    if c in {'A'..'Z'} and i > 0 and name[i-1] != '_' and
        (name[i-1] in {'a'..'z', '0'..'9'} or (i+1 < name.len and name[i+1] in {'a'..'z'})):
      result.add('_')
    result.add(c.toLowerAscii)

proc parseResource*(name: string, fields: seq[string], migration: int): ResourceSpec =
  checkIdentifier(name)
  result.singular = snake(name)
  discard portableRelative(result.singular)
  for part in result.singular.split('_'): result.model.add(part.capitalizeAscii())
  result.plural = result.singular
  if result.plural.endsWith("y") and result.plural.len > 1 and result.plural[^2] notin {'a','e','i','o','u'}:
    result.plural.setLen(result.plural.len-1)
    result.plural.add("ies")
  elif result.plural.endsWith("s") or result.plural.endsWith("x") or
      result.plural.endsWith("z") or result.plural.endsWith("ch") or result.plural.endsWith("sh"):
    result.plural.add("es")
  else: result.plural.add('s')
  discard portableRelative(result.plural)
  result.migration = migration
  if fields.len == 0: fail("resource scaffold needs at least one name:type field")
  var seen = initHashSet[string]()
  seen.incl("id")
  for value in fields:
    let parts = value.split(':')
    if parts.len != 2: fail("expected field name:type: " & value)
    checkIdentifier(parts[0])
    let normalized = identity(parts[0])
    if normalized in seen: fail("duplicate or reserved field: " & parts[0])
    seen.incl(normalized)
    if parts[1] notin ["string", "bool", "int", "float"]:
      fail("unsupported field type: " & parts[1] & "; use string, bool, int or float")
    result.fields.add(FieldSpec(name: parts[0], kind: parts[1]))

proc parseScaffoldOptions*(args: seq[string]): ScaffoldOptions =
  if args.len == 0 or args[0].startsWith("--"):
    fail("usage: leaf g scaffold DIRECTORY | MODEL FIELD:TYPE... --project DIRECTORY [--dry-run]")
  result.target = args[0]
  var i = 1
  var projectSeen, previewSeen: bool
  while i < args.len:
    case args[i]
    of "--project":
      if projectSeen or i+1 >= args.len or args[i+1].len == 0 or args[i+1].startsWith("--"):
        fail("--project requires one directory and cannot be repeated")
      projectSeen = true
      inc i
      result.project = args[i]
    of "--dry-run":
      if previewSeen: fail("duplicated --dry-run")
      previewSeen = true
      result.dryRun = true
    else:
      if args[i].startsWith("-"): fail("unknown scaffold option: " & args[i])
      result.fields.add(args[i])
    inc i
  if not projectSeen and result.fields.len > 0: fail("resource fields require --project DIRECTORY")
