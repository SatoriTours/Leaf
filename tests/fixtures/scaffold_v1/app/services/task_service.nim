from "$lib/system" as nim_system import nil
import leaf/sqlite as storage
from ../models/task as record_model import validate
import std/strutils

type TaskService* = ref object
  database: storage.Database

proc newTaskService*(database: storage.Database): TaskService =
  if database == nil: raise newException(nim_system.ValueError, "Database is required")
  TaskService(database: database)

proc toModel(row: seq[storage.SqlValue]): record_model.Task =
  result.id = row[0].asInt
  result.title = row[1].asString
  result.done = row[2].asBool

proc all*(service: TaskService): seq[record_model.Task] =
  for row in service.database.query("SELECT id, \"title\", \"done\" FROM \"tasks\" ORDER BY id"):
    result.add(toModel(row))

proc find*(service: TaskService, id: int): record_model.Task =
  let rows = service.database.query("SELECT id, \"title\", \"done\" FROM \"tasks\" WHERE id = ?", @[storage.dbValue(id)])
  if rows.len == 0: raise newException(nim_system.ValueError, "Record no longer exists")
  toModel(rows[0])

proc save*(service: TaskService, value: record_model.Task): record_model.Task =
  var candidate = value
  candidate.title = candidate.title.strip()
  candidate.validate()
  let values = @[storage.dbValue(candidate.title), storage.dbValue(candidate.done)]
  if candidate.id == 0:
    discard service.database.execute("INSERT INTO \"tasks\" (\"title\", \"done\") VALUES (?, ?)", values)
    candidate.id = service.database.lastInsertId
  else:
    if service.database.execute("UPDATE \"tasks\" SET \"title\" = ?, \"done\" = ? WHERE id = ?", values & @[storage.dbValue(candidate.id)]) == 0:
      raise newException(nim_system.ValueError, "Record no longer exists")
  candidate

proc delete*(service: TaskService, id: int) =
  if service.database.execute("DELETE FROM \"tasks\" WHERE id = ?", @[storage.dbValue(id)]) == 0:
    raise newException(nim_system.ValueError, "Record no longer exists")
