## Transactional migration runner: command lock, scoped SQL guard, per-step
## atomic commit, graceful cancellation and accurate reports.
import std/[algorithm, options, os, sets]
import ../sqlite
import ./fingerprint
import ./history
import ./locking
import ./planner
import ./sqlite_adapter
import ./types

const
  LockTimeoutMs* = 5000
  ProgressInterval = 1000

type
  ScriptContext = object
    shouldCancel: CancelCheck
    cancelled: bool
    failure: string

proc scriptProgress(context: pointer): cint {.cdecl.} =
  ## C callback: no exception may cross the boundary; failures abort the SQL.
  let state = cast[ptr ScriptContext](context)
  try:
    if state.shouldCancel != nil and state.shouldCancel():
      state.cancelled = true
      return 1
  except Exception as error:
    state.failure = error.msg
    return 1
  0

proc executeMigrationScript*(db: Database, sql: string, shouldCancel: CancelCheck = nil) =
  ## Run one migration script under the framework authorizer and progress
  ## handler; both are removed in finally on success, failure or interruption.
  db.requireUsable()
  db.beginScriptGuard()
  try:
    var state = ScriptContext(shouldCancel: shouldCancel)
    db.installProgress(ProgressInterval, scriptProgress, addr state)
    try:
      try:
        db.executeScript(sql)
      except DatabaseError:
        if state.cancelled:
          raise migrationError("migration_cancelled", "migration SQL was cancelled")
        if state.failure.len > 0:
          raise migrationError("migration_callback_failed", state.failure)
        raise
      if state.cancelled:
        raise migrationError("migration_cancelled", "migration SQL was cancelled")
      if state.failure.len > 0:
        raise migrationError("migration_callback_failed", state.failure)
    finally:
      db.clearProgress()
  finally:
    db.endScriptGuard()

proc migrationLockPath*(db: Database): string =
  ## Canonical `<actual database>.leaf-migrate.lock`, or "" for in-memory.
  let path = db.databaseFile
  if path.len == 0: "" else: expandFilename(path) & ".leaf-migrate.lock"

proc issueFromError(error: ref MigrationError): MigrationIssue =
  MigrationIssue(code: error.issueCode, message: error.msg, file: error.file,
    version: error.migrationVersion, direction: error.direction)

proc commandName(kind: MigrationRequestKind): string =
  case kind
  of mrMigrate: "migrate"
  of mrRollback: "rollback"
  of mrForward: "forward"
  of mrUp: "up"
  of mrDown: "down"
  of mrStatus: "status"

proc rollbackCurrent(db: Database) =
  ## Never mask the original error with a redundant rollback.
  if db.isAutocommit: return
  try:
    discard db.execute("ROLLBACK")
  except DatabaseError:
    discard

proc enrichStep(error: ref MigrationError, step: MigrationStep,
    definition: MigrationDefinition) =
  ## Preserve existing attributes; fill in the selected step identity.
  if error.migrationVersion.isNone: error.migrationVersion = some(step.version)
  if error.file.len == 0: error.file = definition.sourcePath
  if error.direction.isNone: error.direction = some(step.direction)

proc pendingVersions(catalog: openArray[MigrationDefinition],
    history: openArray[MigrationRecord]): seq[int64] =
  var applied = initHashSet[int64]()
  for record in history: applied.incl record.version
  for definition in catalog:
    if definition.version notin applied: result.add definition.version
  result.sort()

proc applyKnownState(outcome: var MigrationResult, catalog: openArray[MigrationDefinition],
    history: openArray[MigrationRecord]) =
  var highest = 0'i64
  for record in history:
    if record.version > highest: highest = record.version
  outcome.currentVersion = some(highest)
  outcome.pendingVersions = pendingVersions(catalog, history)

proc readHistorySafe(db: Database, outcome: var MigrationResult):
    tuple[ok: bool, history: seq[MigrationRecord]] =
  ## Expected DB/read failures become report errors, not escapes.
  try:
    result.history = readMigrationHistory(db)
    result.ok = true
  except MigrationError as error:
    outcome.errors.add issueFromError(error)
  except DatabaseError as error:
    outcome.errors.add MigrationIssue(code: "migration_history_unreadable",
      message: error.msg)

proc refreshState(db: Database, catalog: openArray[MigrationDefinition],
    outcome: var MigrationResult) =
  ## Keep the last known state if a refresh fails; never report unknown as zero.
  try:
    applyKnownState(outcome, catalog, readMigrationHistory(db))
  except MigrationError:
    discard
  except DatabaseError:
    discard

proc checkSelectedCapabilities(db: Database, catalog: openArray[MigrationDefinition],
    plan: MigrationPlan) =
  ## Only the selected directions are gated; an unselected inverse must not
  ## block a valid up on an older SQLite.
  let runtime = sqliteRuntimeVersion()
  for step in plan.steps:
    let index = findDefinition(catalog, step.version)
    if index < 0: continue
    let definition = catalog[index]
    if definition.format == mfSqlV1: continue
    let operations = if step.direction == mdUp: definition.upOps else: definition.downOps
    try:
      checkCapabilities(operations, runtime)
    except MigrationError as error:
      error.migrationVersion = some(definition.version)
      error.file = definition.sourcePath
      error.direction = some(step.direction)
      raise

proc prepareHistory(db: Database, catalog: openArray[MigrationDefinition],
    outcome: var MigrationResult): bool =
  ## One controlled transaction: create or upgrade the history before any step.
  try:
    discard db.execute("BEGIN IMMEDIATE")
    discard createMigrationHistory(db)
    upgradeMigrationHistory(db, catalog)
    discard db.execute("COMMIT")
    return true
  except MigrationError as error:
    rollbackCurrent(db)
    outcome.errors.add issueFromError(error)
  except DatabaseError as error:
    rollbackCurrent(db)
    outcome.errors.add MigrationIssue(code: "migration_history_failed", message: error.msg)
  false

proc insertHistoryRow(db: Database, table: string, definition: MigrationDefinition) =
  let down = if definition.hasDown: dbValue(downFingerprint(definition))
    else: SqlValue(kind: sqlNull)
  discard db.execute("INSERT INTO " & table &
    " (version, name, sql, format, source_sha256, operations_sha256, down_sha256) " &
    "VALUES (?, ?, ?, ?, ?, ?, ?)",
    @[dbValue(definition.version), dbValue(definition.name), dbValue(forwardSql(definition)),
      dbValue(if definition.format == mfNimV1: "nim-v1" else: "sql-v1"),
      dbValue(definition.sourceChecksum), dbValue(operationsFingerprint(definition)), down])

proc cancellationRequested(shouldCancel: CancelCheck): bool =
  if shouldCancel == nil: return false
  try:
    shouldCancel()
  except Exception as error:
    raise migrationError("migration_callback_failed", error.msg)

proc executePlan(db: Database, catalog: openArray[MigrationDefinition],
    plan: MigrationPlan, table: string, shouldCancel: CancelCheck,
    outcome: var MigrationResult) =
  for step in plan.steps:
    let definition = catalog[findDefinition(catalog, step.version)]
    var cancelled = false
    try:
      cancelled = cancellationRequested(shouldCancel)
    except MigrationError as error:
      enrichStep(error, step, definition)
      outcome.errors.add issueFromError(error)
      return
    if cancelled:
      outcome.errors.add MigrationIssue(code: "migration_cancelled",
        message: "migration was cancelled before step " & $step.version,
        version: some(step.version), file: definition.sourcePath,
        direction: some(step.direction))
      return
    var committed = false
    try:
      discard db.execute("BEGIN IMMEDIATE")
      for statement in step.statements:
        executeMigrationScript(db, statement, shouldCancel)
      # A short script can set the cancel flag without ever firing the progress
      # handler; check again before the history write and COMMIT.
      if cancellationRequested(shouldCancel):
        raise migrationError("migration_cancelled", "migration was cancelled")
      if step.direction == mdUp:
        insertHistoryRow(db, table, definition)
      else:
        discard db.execute("DELETE FROM " & table & " WHERE version = ?",
          @[dbValue(step.version)])
      discard db.execute("COMMIT")
      committed = true
    except MigrationError as error:
      rollbackCurrent(db)
      enrichStep(error, step, definition)
      outcome.errors.add issueFromError(error)
      return
    except DatabaseError as error:
      rollbackCurrent(db)
      outcome.errors.add MigrationIssue(code: "migration_sql_failed", message: error.msg,
        version: some(step.version), file: definition.sourcePath,
        direction: some(step.direction))
      return
    if committed:
      outcome.executed.add step

proc runStatus(db: Database, catalog: openArray[MigrationDefinition],
    outcome: var MigrationResult) =
  ## Status on a supplied handle: inspection and report only, no lock or write.
  ## Fatal history issues are promoted to errors (exit 1) while pending-template
  ## and legacy-unverified-down stay non-fatal disclosures.
  try:
    let history = readMigrationHistory(db)
    outcome.statuses = inspectMigrationHistory(catalog, history)
    applyKnownState(outcome, catalog, history)
    for status in outcome.statuses:
      for issue in status.issues:
        if issue.code notin ["pending_template", "legacy_unverified_down"]:
          outcome.errors.add issue
  except MigrationError as error:
    outcome.errors.add issueFromError(error)
    outcome.currentVersion = none(int64)
    outcome.pendingVersions = @[]
  except DatabaseError as error:
    outcome.errors.add MigrationIssue(code: "migration_history_unreadable", message: error.msg)
    outcome.currentVersion = none(int64)
    outcome.pendingVersions = @[]

proc runMigrations*(db: Database, catalog: openArray[MigrationDefinition],
    request: MigrationRequest, shouldCancel: CancelCheck = nil): MigrationResult =
  result.command = commandName(request.kind)
  result.executionConfirmed = true
  try:
    db.requireUsable()
  except DatabaseError as error:
    result.errors.add MigrationIssue(code: "database_unusable", message: error.msg)
    return
  result.database = db.databaseFile
  if request.kind == mrStatus:
    runStatus(db, catalog, result)
    return
  if not db.isAutocommit:
    result.errors.add MigrationIssue(code: "active_transaction",
      message: "a business transaction is already active")
    return
  try:
    db.beginMigrationRunner()
  except ScopeError as error:
    result.errors.add MigrationIssue(code: error.scopeCode, message: error.msg)
    return
  var lock: FileLock
  try:
    # Read once before the lock so an unreadable history fails fast and the
    # known state is available for later error reports.
    let initial = readHistorySafe(db, result)
    if not initial.ok: return
    var history = initial.history
    applyKnownState(result, catalog, history)
    let lockPath = migrationLockPath(db)
    if lockPath.len > 0:
      try:
        lock = acquireFileLock(lockPath, LockTimeoutMs)
      except MigrationError as error:
        result.errors.add issueFromError(error)
        return
    # After the lock: re-read, revalidate and replan. The full selected-plan
    # preflight still happens before any history or DDL mutation.
    let locked = readHistorySafe(db, result)
    if not locked.ok: return
    history = locked.history
    applyKnownState(result, catalog, history)
    var plan: MigrationPlan
    try:
      plan = planMigrations(catalog, history, request)
      checkSelectedCapabilities(db, catalog, plan)
    except MigrationError as error:
      result.errors.add issueFromError(error)
      return
    result.planned = plan.steps
    result.skipped = plan.skipped
    if not prepareHistory(db, catalog, result): return
    executePlan(db, catalog, plan, migrationHistoryTable(db), shouldCancel, result)
    refreshState(db, catalog, result)
  finally:
    if lock != nil: lock.release()
    db.endMigrationRunner()

proc migrate*(db: Database, catalog: openArray[MigrationDefinition]) =
  ## Startup entry point: raise on any failure instead of returning a report.
  let outcome = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
  if outcome.errors.len > 0:
    raiseIssue(outcome.errors[0])
