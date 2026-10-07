import std/[sequtils, strutils, options, times]
import ../sqlite
import ./[record, metadata, context, errors, changes, callbacks, validation, transactions]
import ./adapters/norm_sqlite

proc selectedColumns*[T: Record](_: typedesc[T]): string =
  mixin modelFields
  modelFields(T).mapIt(quoteIdentifier(it.name)).join(", ")

proc find*[T: Record](_: typedesc[T], id: int64): T =
  mixin modelTable, storageType, fromStorage
  let db = currentDatabase()
  let sql = "SELECT " & selectedColumns(T) & " FROM " & quoteIdentifier(modelTable(T)) & " WHERE \"id\"=? LIMIT 1"
  let rows = selectStorage[storageType(T)](db, sql, @[dbValue(id)])
  if rows.len == 0: raise newException(RecordNotFound, "record not found: " & modelTable(T) & " id=" & $id)
  fromStorage(T, rows[0], db)

proc find*[T: Record](_: typedesc[T], db: Database, id: int64): T =
  withDatabase(db): result = find(T, id)

proc writtenChanges[T: Record](record: T, values: FieldValues): ChangeSet =
  mixin modelFields
  let baseline = record.originalValues
  for field in modelFields(T):
    if field.name == "id": continue
    let value = values.valueFor(field.name)
    let previous = if record.isNewRecord: none(SqlValue) else: some(baseline.valueFor(field.name))
    if previous.isNone or previous.get != value:
      result.add(FieldChange(field: field.name, before: previous, after: some(value)))

proc queueCallbacks[T: Record](record: T, event: ModelEvent) =
  mixin runCallbacks
  queueEvent(record, event,
    proc() = runCallbacks(record, afterCommitPhase, event),
    proc() = runCallbacks(record, afterRollbackPhase, event))

proc save*[T: Record](record: T): bool =
  mixin modelTable, modelValues, toStorage, runCallbacks
  record.requireRecord()
  if record.isDestroyed: raise newException(ModelUsageError, "cannot save a destroyed record")
  let db = currentDatabase()
  record.beginOperation(db)
  try:
    let frame = beginFrame()
    try:
      let state = captureState(record)
      enlist(record, proc() = restoreState(record, state))
      if not validateInOperation(record):
        frame.rollbackFrame()
        return false
      let inserting = record.isNewRecord
      runCallbacks(record, beforeSavePhase)
      if not record.operationAborted:
        runCallbacks(record, if inserting: beforeCreatePhase else: beforeUpdatePhase)
      if record.operationAborted:
        frame.rollbackFrame()
        return false
      let dirty = record.changes
      when T is TimestampedRecord:
        if inserting:
          let timestamp = now().toTime.toUnixFloat.fromUnixFloat.utc
          record.created_at = some(timestamp)
          record.updated_at = some(timestamp)
        else:
          record.created_at = fieldFromValue(record.originalValues.valueFor("created_at"), Option[DateTime])
          record.updated_at = if dirty.len > 0: some(now().toTime.toUnixFloat.fromUnixFloat.utc)
            else: fieldFromValue(record.originalValues.valueFor("updated_at"), Option[DateTime])
      let values = modelValues(record)
      let delta = writtenChanges(record, values)
      if inserting:
        var stored = toStorage(record)
        db.insertStorage(stored)
        record.acceptPersistedValues(db, stored.id, values, delta)
        record.queueCallbacks(newModelEvent(createOperation, delta))
      elif dirty.len > 0:
        var assignments: seq[string]
        var parameters: seq[SqlValue]
        for change in delta:
          assignments.add(quoteIdentifier(change.field) & "=?")
          parameters.add(change.after.get)
        parameters.add(dbValue(record.id))
        if db.executeAffected("UPDATE " & quoteIdentifier(modelTable(T)) & " SET " & assignments.join(", ") &
            " WHERE \"id\"=?", parameters) != 1:
          raise newException(RecordNotFound, "record disappeared before update")
        record.acceptPersistedValues(db, record.id, values, delta)
        record.queueCallbacks(newModelEvent(updateOperation, delta))
      else:
        if db.query("SELECT 1 FROM " & quoteIdentifier(modelTable(T)) & " WHERE \"id\"=?", @[dbValue(record.id)]).len == 0:
          raise newException(RecordNotFound, "record disappeared before save")
        record.acceptPersistedValues(db, record.id, values, @[])
      runCallbacks(record, if inserting: afterCreatePhase else: afterUpdatePhase)
      runCallbacks(record, afterSavePhase)
      frame.commitFrame()
      result = true
    except Exception:
      if frame.isActive:
        try: frame.rollbackFrame()
        except CatchableError: discard
      raise
  finally: record.endOperation()

proc saveOrRaise*[T: Record](record: T) =
  if not record.save():
    if record.operationAborted: raise newException(RecordNotSaved, "save cancelled by before callback")
    raise newException(RecordInvalid, record.errors.fullMessages.join("\n"))

proc save*[T: Record](record: T, db: Database): bool =
  withDatabase(db): result = record.save()
proc saveOrRaise*[T: Record](record: T, db: Database) =
  withDatabase(db): record.saveOrRaise()

proc reload*[T: Record](record: T) =
  mixin modelValues, assignModelValues
  record.requireRecord()
  if not record.isPersisted: raise newException(ModelUsageError, "reload requires a persisted record")
  let db = currentDatabase()
  record.beginOperation(db)
  try:
    let loaded = find(T, record.id)
    let values = modelValues(loaded)
    assignModelValues(record, values)
    record.markLoaded(db, loaded.id, values)
    record.errors.clear()
  finally: record.endOperation()
proc reload*[T: Record](record: T, db: Database) =
  withDatabase(db): record.reload()

proc destroy*[T: Record](record: T): bool =
  mixin modelTable, runCallbacks
  record.requireRecord()
  if record.isDestroyed: raise newException(ModelUsageError, "record is already destroyed")
  let db = currentDatabase()
  record.beginOperation(db)
  try:
    let frame = beginFrame()
    try:
      let state = captureState(record)
      enlist(record, proc() = restoreState(record, state))
      runCallbacks(record, beforeDestroyPhase)
      if record.operationAborted:
        frame.rollbackFrame()
        return false
      if record.isPersisted:
        if db.executeAffected("DELETE FROM " & quoteIdentifier(modelTable(T)) & " WHERE \"id\"=?", @[dbValue(record.id)]) != 1:
          raise newException(RecordNotFound, "record disappeared before destroy")
        record.queueCallbacks(newModelEvent(destroyOperation, @[]))
      record.markDestroyed()
      runCallbacks(record, afterDestroyPhase)
      frame.commitFrame()
      result = true
    except Exception:
      if frame.isActive:
        try: frame.rollbackFrame()
        except CatchableError: discard
      raise
  finally: record.endOperation()

proc destroyOrRaise*[T: Record](record: T) =
  if not record.destroy(): raise newException(RecordNotDestroyed, "destroy cancelled by before callback")
proc destroy*[T: Record](record: T, db: Database): bool =
  withDatabase(db): result = record.destroy()
proc destroyOrRaise*[T: Record](record: T, db: Database) =
  withDatabase(db): record.destroyOrRaise()
