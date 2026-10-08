## Read-only migration history: legacy compatibility, inspection and a
## caller-transaction upgrade. Reads and inspect never write.
import std/[algorithm, options, sets, strutils]
import ./fingerprint
import ./planner
import ./types
import ../sqlite

const
  HistoryTable = "leaf_schema_migrations"
  LegacyColumns = ["version", "name", "sql"]
  MetadataColumns = ["format", "source_sha256", "operations_sha256", "down_sha256"]

proc historyObject(db: Database): string =
  let rows = db.query("SELECT type FROM sqlite_master WHERE name = ?", @[dbValue(HistoryTable)])
  if rows.len == 0: "" else: rows[0][0].asString

proc historyColumns(db: Database): seq[string] =
  for row in db.query("PRAGMA table_info(" & HistoryTable & ")"):
    result.add row[1].asString

proc optionalText(value: SqlValue, column: string): string =
  case value.kind
  of sqlNull: ""
  of sqlText: value.text
  else: raise migrationError("corrupt_history", "history " & column & " is not text")

proc readMigrationHistory*(db: Database): seq[MigrationRecord] =
  ## A missing history table is empty history. A corrupt table, shape, type,
  ## null or duplicate is an explicit error, never coerced into safe history.
  let kind = historyObject(db)
  if kind.len == 0: return @[]
  if kind != "table":
    raise migrationError("corrupt_history", HistoryTable & " is not a table: " & kind)
  let columns = historyColumns(db)
  for required in LegacyColumns:
    if required notin columns:
      raise migrationError("corrupt_history", HistoryTable & " is missing column " & required)
  var selected: seq[string] = @LegacyColumns
  for metadata in MetadataColumns:
    if metadata in columns: selected.add metadata
  let formatIndex = selected.find("format")
  let sourceIndex = selected.find("source_sha256")
  let operationsIndex = selected.find("operations_sha256")
  let downIndex = selected.find("down_sha256")
  var seen = initHashSet[int64]()
  for row in db.query("SELECT " & selected.join(", ") & " FROM " & HistoryTable &
      " ORDER BY version"):
    if row[0].kind != sqlInteger:
      raise migrationError("corrupt_history", "history version is not an integer")
    let version = row[0].asInt64
    if version <= 0:
      raise migrationError("corrupt_history", "history version must be positive")
    if row[1].kind != sqlText or row[1].asString.len == 0:
      raise migrationError("corrupt_history", "history name is missing")
    if row[2].kind != sqlText or row[2].asString.len == 0:
      raise migrationError("corrupt_history", "history sql is missing")
    if version in seen:
      raise migrationError("corrupt_history", "duplicate history version " & $version)
    seen.incl version
    var record = MigrationRecord(version: version, name: row[1].asString, sql: row[2].asString)
    if formatIndex >= 0:
      if row[formatIndex].kind != sqlText or row[formatIndex].asString.len == 0:
        raise migrationError("corrupt_history", "history format is missing")
      record.format = row[formatIndex].asString
    else:
      # The metadata columns are truly absent: legacy rows are sql-v1.
      record.format = "sql-v1"
    if sourceIndex >= 0: record.sourceChecksum = optionalText(row[sourceIndex], "source_sha256")
    if operationsIndex >= 0:
      record.operationsChecksum = optionalText(row[operationsIndex], "operations_sha256")
    if downIndex >= 0: record.downChecksum = optionalText(row[downIndex], "down_sha256")
    result.add record

proc statusRank(code: string): int =
  case code
  of "corrupt_history": 5
  of "unknown_history_format": 4
  of "history_missing_file": 3
  of "legacy_unverified_down": 1
  else: (if code.startsWith("history_"): 2 else: 0)

proc stateFor(issues: seq[MigrationIssue]): string =
  var best = 0
  result = "applied"
  for issue in issues:
    let rank = statusRank(issue.code)
    if rank > best:
      best = rank
      case issue.code
      of "corrupt_history": result = "corrupt"
      of "unknown_history_format": result = "unknown-format"
      of "history_missing_file": result = "missing"
      of "legacy_unverified_down": result = "legacy-unverified-down"
      else: result = "modified"

proc inspectMigrationHistory*(catalog: openArray[MigrationDefinition],
    history: openArray[MigrationRecord]): seq[MigrationStatus] =
  ## Status/preview only: concrete issues, no repairs and no history writes.
  let catalogProblems = catalogIssues(catalog)
  if catalogProblems.len > 0:
    raise migrationError(catalogProblems[0].code, catalogProblems[0].message)
  var applied = initHashSet[int64]()
  for record in history:
    if record.version in applied:
      raise migrationError("corrupt_history", "duplicate applied version " & $record.version)
    applied.incl record.version
    let issues = recordIssues(catalog, record)
    result.add MigrationStatus(version: record.version, name: record.name,
      file: record.name, state: stateFor(issues), issues: issues)
  for definition in catalog:
    if definition.version notin applied:
      var status = MigrationStatus(version: definition.version, name: definition.name,
        file: definition.sourcePath,
        state: if definition.pending: "pending-template" else: "pending")
      if definition.pending:
        status.issues.add MigrationIssue(code: "pending_template",
          message: "migration is an unfinished pending template", file: definition.sourcePath,
          version: some(definition.version))
      result.add status
  result.sort(proc(left, right: MigrationStatus): int = cmp(left.version, right.version))

proc upgradeMigrationHistory*(db: Database, catalog: openArray[MigrationDefinition]) =
  ## Adds the four metadata columns and captures the first legacy baseline.
  ## The caller owns the transaction: no COMMIT here, so it is rollbackable and
  ## idempotent, and applied rows keep their exact name/up SQL.
  let kind = historyObject(db)
  if kind.len == 0: return
  if kind != "table":
    raise migrationError("corrupt_history", HistoryTable & " is not a table: " & kind)
  let problems = catalogIssues(catalog)
  if problems.len > 0:
    raise migrationError(problems[0].code, problems[0].message)
  let history = readMigrationHistory(db)
  for record in history:
    for issue in recordIssues(catalog, record):
      if issue.code != "legacy_unverified_down":
        raise migrationError(issue.code, issue.message)
  let columns = historyColumns(db)
  if "format" notin columns:
    db.executeScript("ALTER TABLE " & HistoryTable &
      " ADD COLUMN format TEXT NOT NULL DEFAULT 'sql-v1';")
  if "source_sha256" notin columns:
    db.executeScript("ALTER TABLE " & HistoryTable & " ADD COLUMN source_sha256 TEXT;")
  if "operations_sha256" notin columns:
    db.executeScript("ALTER TABLE " & HistoryTable & " ADD COLUMN operations_sha256 TEXT;")
  if "down_sha256" notin columns:
    db.executeScript("ALTER TABLE " & HistoryTable & " ADD COLUMN down_sha256 TEXT;")
  for record in history:
    let index = findDefinition(catalog, record.version)
    if index < 0: continue
    let definition = catalog[index]
    if definition.format == mfSqlV1 and record.sourceChecksum.len == 0:
      # The down baseline is captured now for future checks; the past down was
      # never recorded and cannot be claimed as historically validated.
      let down = if definition.hasDown: dbValue(downFingerprint(definition))
        else: SqlValue(kind: sqlNull)
      discard db.execute("UPDATE " & HistoryTable &
        " SET source_sha256 = ?, operations_sha256 = ?, down_sha256 = ? WHERE version = ?",
        @[dbValue(definition.sourceChecksum), dbValue(operationsFingerprint(definition)),
          down, dbValue(record.version)])
