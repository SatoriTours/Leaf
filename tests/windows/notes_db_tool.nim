
## Guest helper for the Notes acceptance slice: hold a second write lock or check a database.
## Not named test_*.nim so the Windows runner ignores it. It only works on an existing
## acceptance database that already contains the notes table, and never clamps inputs.
import std/[os, strutils, times]
import leaf/sqlite

proc fail(message: string) {.noreturn.} =
  stderr.writeLine("error: " & message)
  quit 2

proc requireNotesTable(db: Database, path: string) =
  let rows = db.query("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='notes'")
  if rows.len == 0 or rows[0][0].asInt != 1:
    fail("refusing unknown database (no notes table): " & path)

if paramCount() < 1: fail("usage: notes_db_tool lock|check ...")
let mode = paramStr(1)
case mode
of "lock":
  if paramCount() < 4: fail("usage: notes_db_tool lock <db> <holdMs 1..15000> <marker>")
  let path = paramStr(2)
  let marker = paramStr(4)
  var holdMs = 0
  try:
    holdMs = parseInt(paramStr(3))
  except ValueError:
    fail("holdMs must be an integer")
  if holdMs < 1 or holdMs > 15000: fail("holdMs out of range 1..15000 (no clamping)")
  if not fileExists(path): fail("database missing: " & path)
  if fileExists(marker): fail("marker already exists: " & marker)
  let db = openDatabase(path)
  var begun = false
  try:
    requireNotesTable(db, path)
    echo "journal_mode=", db.query("PRAGMA journal_mode")[0][0].asString
    echo "busy_timeout=", db.query("PRAGMA busy_timeout")[0][0].asInt
    discard db.execute("BEGIN IMMEDIATE")
    begun = true
    writeFile(marker, "pid=" & $getCurrentProcessId() & " holdMs=" & $holdMs & " ts=" & $epochTime())
    echo "locked marker=", readFile(marker)
    sleep(holdMs)
  finally:
    if begun:
      try:
        discard db.execute("ROLLBACK")
        echo "rolledback=true"
      except CatchableError as error:
        echo "rollback_error=", error.msg
    db.close()
    if fileExists(marker):
      removeFile(marker)
    echo "marker_removed=", not fileExists(marker)
of "check":
  if paramCount() < 2: fail("usage: notes_db_tool check <db> [outFile]")
  let path = paramStr(2)
  if not fileExists(path): fail("database missing: " & path)
  let db = openDatabaseReadOnly(path)
  var lines: seq[string]
  try:
    requireNotesTable(db, path)
    lines.add "integrity=" & db.query("PRAGMA integrity_check")[0][0].asString
    lines.add "notes=" & $db.query("SELECT COUNT(*) FROM notes")[0][0].asInt
    for row in db.query("SELECT title, archived, favorite FROM notes ORDER BY id DESC LIMIT 5"):
      lines.add "row=" & row[0].asString & "|archived=" & $row[1].asInt & "|favorite=" & $row[2].asInt
  finally:
    db.close()
  for line in lines: echo line
  if paramCount() >= 3: writeFile(paramStr(3), lines.join("\n") & "\n")
of "lookup":
  if paramCount() < 2: fail("usage: notes_db_tool lookup <db> <exactTitle> [outFile]")
  let path = paramStr(2)
  if not fileExists(path): fail("database missing: " & path)
  let wanted = paramStr(3)
  let db = openDatabaseReadOnly(path)
  var lines: seq[string]
  try:
    requireNotesTable(db, path)
    let rows = db.query("SELECT id, title, length(body), favorite, archived FROM notes WHERE title = ?", @[dbValue(wanted)])
    lines.add "matches=" & $rows.len
    if rows.len == 1:
      lines.add "id=" & $rows[0][0].asInt
      lines.add "title_len=" & $rows[0][1].asString.len
      lines.add "body_len=" & $rows[0][2].asInt
      lines.add "favorite=" & $rows[0][3].asInt
      lines.add "archived=" & $rows[0][4].asInt
    lines.add "integrity=" & db.query("PRAGMA integrity_check")[0][0].asString
    lines.add "total=" & $db.query("SELECT COUNT(*) FROM notes")[0][0].asInt
  finally:
    db.close()
  for line in lines: echo line
  if paramCount() >= 4: writeFile(paramStr(4), lines.join("\n") & "\n")
  if lines.len > 0 and lines[0] != "matches=1": quit 3
of "show":
  if paramCount() < 2: fail("usage: notes_db_tool show <db> <id> [outFile]")
  let path = paramStr(2)
  if not fileExists(path): fail("database missing: " & path)
  var wantedId = 0
  try:
    wantedId = parseInt(paramStr(3))
  except ValueError:
    fail("id must be an integer")
  let db = openDatabaseReadOnly(path)
  var lines: seq[string]
  try:
    requireNotesTable(db, path)
    let rows = db.query("SELECT id, title, length(body), favorite, archived, updated FROM notes WHERE id = ?", @[dbValue(wantedId)])
    lines.add "matches=" & $rows.len
    if rows.len == 1:
      lines.add "id=" & $rows[0][0].asInt
      lines.add "title_len=" & $rows[0][1].asString.len
      lines.add "body_len=" & $rows[0][2].asInt
      lines.add "favorite=" & $rows[0][3].asInt
      lines.add "archived=" & $rows[0][4].asInt
      lines.add "updated_len=" & $rows[0][5].asString.len
    lines.add "integrity=" & db.query("PRAGMA integrity_check")[0][0].asString
    lines.add "total=" & $db.query("SELECT COUNT(*) FROM notes")[0][0].asInt
  finally:
    db.close()
  for line in lines: echo line
  if paramCount() >= 4: writeFile(paramStr(4), lines.join("\n") & "\n")
  if lines.len > 0 and lines[0] != "matches=1": quit 3
else:
  fail("usage: notes_db_tool lock|check ...")
