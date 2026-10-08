## Typed migration descriptions shared by the DSL, SQLite adapter and planner.
## SqlValue and DatabaseError intentionally reuse the existing leaf/sqlite types.
import std/options
import ../sqlite

type
  MigrationFormat* = enum
    mfNimV1, mfSqlV1
  ColumnKind* = enum
    ckText, ckInteger, ckReal, ckBoolean, ckDateTime
  ColumnSpec* = object
    name*: string
    kind*: ColumnKind
    nullable*: bool
    defaultValue*: Option[SqlValue]
  TableSpec* = object
    name*: string
    columns*: seq[ColumnSpec]
    hasId*: bool
    autoIncrement*: bool
  IndexSpec* = object
    table*, name*: string
    columns*: seq[string]
    unique*: bool
  SchemaOperationKind* = enum
    moCreateTable, moDropTable, moAddColumn, moRemoveColumn,
    moRenameTable, moRenameColumn, moAddIndex, moRemoveIndex
  SchemaOperation* = object
    case kind*: SchemaOperationKind
    of moCreateTable, moDropTable:
      tableSpec*: TableSpec
      tableDefinitionProvided*: bool
    of moAddColumn, moRemoveColumn:
      tableName*: string
      columnSpec*: ColumnSpec
      columnDefinitionProvided*: bool
    of moRenameTable:
      oldTableName*, newTableName*: string
    of moRenameColumn:
      columnTableName*, oldColumnName*, newColumnName*: string
    of moAddIndex, moRemoveIndex:
      indexSpec*: IndexSpec
  MigrationDefinition* = object
    version*: int64
    name*, sourcePath*, sourceChecksum*: string
    format*: MigrationFormat
    upOps*, downOps*: seq[SchemaOperation]
    legacyUp*, legacyDown*: string
    hasDown*, pending*: bool
  MigrationRequestKind* = enum
    mrMigrate, mrRollback, mrForward, mrUp, mrDown, mrStatus
  MigrationRequest* = object
    kind*: MigrationRequestKind
    target*: Option[int64]
    steps*: int
  MigrationRecord* = object
    version*: int64
    name*, sql*, format*, sourceChecksum*, operationsChecksum*, downChecksum*: string
  MigrationDirection* = enum
    mdUp, mdDown
  MigrationStep* = object
    version*: int64
    direction*: MigrationDirection
    statements*: seq[string]
    name*, sourcePath*: string
  MigrationPlan* = object
    steps*: seq[MigrationStep]
    skipped*: seq[int64]
  MigrationIssue* = object
    code*, message*, file*: string
    version*: Option[int64]
    direction*: Option[MigrationDirection]
  MigrationStatus* = object
    version*: int64
    name*, file*, state*: string
    issues*: seq[MigrationIssue]
  MigrationResult* = object
    command*, database*: string
    dryRun*, executionConfirmed*: bool
    planned*, executed*: seq[MigrationStep]
    skipped*: seq[int64]
    currentVersion*: Option[int64]
    pendingVersions*: seq[int64]
    statuses*: seq[MigrationStatus]
    errors*: seq[MigrationIssue]
  MigrationError* = object of DatabaseError
    issueCode*: string
    migrationVersion*: Option[int64]
    file*: string
    direction*: Option[MigrationDirection]
  CancelCheck* = proc(): bool {.closure.}

proc migrationError*(code, message: string): ref MigrationError =
  ## Stable, machine-readable migration failures for status and JSON reports.
  result = newException(MigrationError, message)
  result.issueCode = code
