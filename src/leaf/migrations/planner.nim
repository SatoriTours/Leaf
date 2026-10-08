## Pure migration planning: validates the catalog and the complete applied
## history, then selects directions. No database, file or lock access.
import std/[algorithm, options, sets, strutils, tables]
import ../core
import ./files
import ./fingerprint
import ./sqlite_adapter
import ./types

proc forwardSql*(definition: MigrationDefinition): string =
  ## Frozen deterministic forward SQL used by history validation and by the
  ## later runner when it records an applied migration: exact legacy bytes for
  ## SQL migrations, otherwise the rendered Nim operations joined with ";\n"
  ## and terminated by one ";". No SQL parsing or source reinterpretation.
  if definition.format == mfSqlV1:
    definition.legacyUp
  else:
    let statements = renderStatements(definition.upOps)
    if statements.len == 0: "" else: statements.join(";\n") & ";"

proc findDefinition*(catalog: openArray[MigrationDefinition], version: int64): int =
  for index, definition in catalog:
    if definition.version == version: return index
  -1

proc logicalName(definition: MigrationDefinition): string =
  ## SQL descriptors carry the numeric basename; duplicates compare logically.
  if definition.format == mfSqlV1:
    try:
      parseMigrationIdentity(definition.name & ".sql").name
    except UiError:
      definition.name
  else:
    definition.name

proc issueFor(definition: MigrationDefinition, code, message: string): MigrationIssue =
  MigrationIssue(code: code, message: message, file: definition.sourcePath,
    version: some(definition.version))

proc recordIssue(record: MigrationRecord, path, code, message: string): MigrationIssue =
  MigrationIssue(code: code, message: message, file: path, version: some(record.version))

proc bareIssue*(record: MigrationRecord, code, message: string): MigrationIssue =
  ## No known definition: there is no actual source path to fabricate.
  recordIssue(record, "", code, message)

proc raiseIssue*(issue: MigrationIssue,
    direction = none(MigrationDirection)) {.noreturn.} =
  let error = migrationError(issue.code, issue.message)
  error.migrationVersion = issue.version
  error.file = issue.file
  error.direction = if direction.isSome: direction else: issue.direction
  raise error

proc catalogIssues*(catalog: openArray[MigrationDefinition]): seq[MigrationIssue] =
  var byVersion: Table[int64, int]
  var byName: Table[string, int]
  for index, definition in catalog:
    if definition.version <= 0:
      result.add issueFor(definition, "invalid_migration_version",
        "migration version must be positive")
    if definition.name.len == 0:
      result.add issueFor(definition, "invalid_migration_name", "migration name is empty")
    if definition.format == mfSqlV1:
      try:
        let identity = parseMigrationIdentity(definition.name & ".sql")
        if identity.version != definition.version:
          result.add issueFor(definition, "migration_identity_mismatch",
            "SQL descriptor " & definition.name & " does not match version " &
            $definition.version)
      except UiError:
        result.add issueFor(definition, "invalid_migration_name",
          "SQL descriptor name is not a numeric migration basename: " & definition.name)
    let logical = logicalName(definition)
    if definition.version in byVersion:
      result.add issueFor(definition, "duplicate_migration_version",
        "duplicate migration version " & $definition.version)
    else:
      byVersion[definition.version] = index
    if logical in byName:
      result.add issueFor(definition, "duplicate_migration_name",
        "duplicate migration name " & logical)
    else:
      byName[logical] = index
    if definition.pending:
      if definition.upOps.len > 0 or definition.legacyUp.len > 0:
        result.add issueFor(definition, "invalid_pending_migration",
          "pending migration must not declare operations")
    else:
      if definition.format == mfNimV1 and definition.upOps.len == 0:
        result.add issueFor(definition, "empty_migration", "migration has no up operations")
      if definition.format == mfSqlV1 and definition.legacyUp.len == 0:
        result.add issueFor(definition, "empty_migration", "migration has no up SQL")
    if definition.hasDown:
      if definition.format == mfNimV1 and definition.downOps.len == 0:
        result.add issueFor(definition, "invalid_migration_down",
          "migration declares a down but has no down operations")
      if definition.format == mfSqlV1 and definition.legacyDown.len == 0:
        result.add issueFor(definition, "invalid_migration_down",
          "migration declares a down but has no down SQL")

proc recordIssues*(catalog: openArray[MigrationDefinition],
    record: MigrationRecord): seq[MigrationIssue] =
  # Resolve identity first so even an unknown-format or corrupt row reports the
  # real source path when its version is known; a missing version stays empty.
  let index = findDefinition(catalog, record.version)
  let knownPath = if index >= 0: catalog[index].sourcePath else: ""
  if record.version <= 0 or record.name.len == 0 or record.sql.len == 0:
    return @[recordIssue(record, knownPath, "corrupt_history",
      "history row is missing version, name or sql")]
  if record.format notin ["sql-v1", "nim-v1"]:
    return @[recordIssue(record, knownPath, "unknown_history_format",
      "unknown history format: " & record.format)]
  if index < 0:
    return @[recordIssue(record, knownPath, "history_missing_file",
      "no migration file for applied version " & $record.version)]
  let definition = catalog[index]
  let expectedFormat = if definition.format == mfNimV1: "nim-v1" else: "sql-v1"
  if record.format != expectedFormat:
    result.add issueFor(definition, "history_format_modified",
      "applied migration format changed: " & record.format & " -> " & expectedFormat)
  if definition.pending:
    result.add issueFor(definition, "history_modified",
      "applied migration is now a pending template")
  if record.name != definition.name:
    result.add issueFor(definition, "history_name_modified",
      "applied migration name changed: " & record.name & " -> " & definition.name)
  if record.sql != forwardSql(definition):
    result.add issueFor(definition, "history_sql_modified", "applied migration SQL changed")
  if definition.format == mfNimV1:
    if record.sourceChecksum.len == 0 or record.operationsChecksum.len == 0 or
        (definition.hasDown and record.downChecksum.len == 0):
      result.add issueFor(definition, "history_missing_fingerprint",
        "Nim history row is missing recorded fingerprints")
    else:
      if record.sourceChecksum != definition.sourceChecksum:
        result.add issueFor(definition, "history_source_modified",
          "applied migration source changed")
      if record.operationsChecksum != operationsFingerprint(definition):
        result.add issueFor(definition, "history_operations_modified",
          "applied migration operations changed")
      if record.downChecksum != downFingerprint(definition):
        result.add issueFor(definition, "history_down_modified",
          "applied migration down changed")
  else:
    if record.sourceChecksum.len > 0 and record.sourceChecksum != definition.sourceChecksum:
      result.add issueFor(definition, "history_source_modified", "applied SQL source changed")
    if record.operationsChecksum.len > 0 and
        record.operationsChecksum != operationsFingerprint(definition):
      result.add issueFor(definition, "history_operations_modified",
        "applied SQL operations changed")
    if definition.hasDown:
      if record.downChecksum.len == 0:
        result.add issueFor(definition, "legacy_unverified_down",
          "down migration was never historically verified")
      elif record.downChecksum != downFingerprint(definition):
        result.add issueFor(definition, "history_down_modified", "applied SQL down changed")
    elif record.downChecksum.len > 0:
      result.add issueFor(definition, "history_down_modified",
        "history has a down fingerprint but the migration has no down")

proc checkSelectable(definition: MigrationDefinition, direction: MigrationDirection) =
  if definition.pending:
    raiseIssue(issueFor(definition, "pending_migration",
      "migration " & $definition.version & " is a pending template"), some(direction))
  if direction == mdDown:
    if not definition.hasDown:
      raiseIssue(issueFor(definition, "missing_migration_down",
        "migration " & $definition.version & " has no down migration"), some(direction))
    if definition.format == mfSqlV1:
      if definition.legacyDown.len == 0:
        raiseIssue(issueFor(definition, "missing_migration_down",
          "migration " & $definition.version & " has no down SQL"), some(direction))
    elif definition.downOps.len == 0:
      raiseIssue(issueFor(definition, "missing_migration_down",
        "migration " & $definition.version & " has no down operations"), some(direction))

proc stepFor(definition: MigrationDefinition, direction: MigrationDirection): MigrationStep =
  result.version = definition.version
  result.direction = direction
  result.name = definition.name
  result.sourcePath = definition.sourcePath
  if definition.format == mfSqlV1:
    result.statements = @[if direction == mdUp: definition.legacyUp else: definition.legacyDown]
  elif direction == mdUp:
    result.statements = renderStatements(definition.upOps)
  else:
    result.statements = renderStatements(definition.downOps)

proc planMigrations*(catalog: openArray[MigrationDefinition],
    history: openArray[MigrationRecord], request: MigrationRequest): MigrationPlan =
  ## Full catalog and applied-history preflight precedes any selection, so a
  ## later irreversible or pending step can never allow earlier writes.
  let catalogProblems = catalogIssues(catalog)
  if catalogProblems.len > 0:
    raiseIssue(catalogProblems[0])
  var applied = initHashSet[int64]()
  for record in history:
    if record.version in applied:
      raiseIssue(bareIssue(record, "corrupt_history",
        "duplicate applied version " & $record.version))
    applied.incl record.version
    if request.kind != mrStatus:
      for issue in recordIssues(catalog, record):
        if issue.code != "legacy_unverified_down":
          raiseIssue(issue)
  var pendingVersions: seq[int64]
  var appliedVersions: seq[int64]
  for definition in catalog:
    if definition.version in applied: appliedVersions.add definition.version
    else: pendingVersions.add definition.version
  pendingVersions.sort()
  appliedVersions.sort()
  var selected: seq[tuple[version: int64, direction: MigrationDirection]]
  case request.kind
  of mrMigrate:
    if request.target.isNone:
      for version in pendingVersions: selected.add (version, mdUp)
    else:
      let target = request.target.get()
      if target < 0:
        raiseIssue(MigrationIssue(code: "invalid_migration_target",
          message: "migration target must not be negative", file: "", version: none(int64)))
      elif target == 0:
        if appliedVersions.len > 0:
          for index in countdown(appliedVersions.high, 0):
            selected.add (appliedVersions[index], mdDown)
      else:
        let index = findDefinition(catalog, target)
        if index < 0:
          raiseIssue(MigrationIssue(code: "invalid_migration_target",
            message: "no migration with version " & $target, file: "",
            version: some(target)))
        if appliedVersions.len > 0:
          for position in countdown(appliedVersions.high, 0):
            if appliedVersions[position] > target:
              selected.add (appliedVersions[position], mdDown)
        for version in pendingVersions:
          if version <= target: selected.add (version, mdUp)
  of mrRollback:
    if request.steps <= 0:
      raiseIssue(MigrationIssue(code: "invalid_migration_steps",
        message: "rollback steps must be positive", file: "", version: none(int64)))
    var taken = 0
    if appliedVersions.len > 0:
      for index in countdown(appliedVersions.high, 0):
        if taken >= request.steps: break
        selected.add (appliedVersions[index], mdDown)
        inc taken
  of mrForward:
    if request.steps <= 0:
      raiseIssue(MigrationIssue(code: "invalid_migration_steps",
        message: "forward steps must be positive", file: "", version: none(int64)))
    var taken = 0
    for version in pendingVersions:
      if taken >= request.steps: break
      selected.add (version, mdUp)
      inc taken
  of mrUp, mrDown:
    if request.target.isNone:
      raiseIssue(MigrationIssue(code: "invalid_migration_target",
        message: "up/down requires a target version", file: "", version: none(int64)))
    let target = request.target.get()
    let index = if target > 0: findDefinition(catalog, target) else: -1
    if target <= 0 or index < 0:
      raiseIssue(MigrationIssue(code: "invalid_migration_target",
        message: "no migration with version " & $target, file: "",
        version: (if target > 0: some(target) else: none(int64))))
    let isApplied = target in applied
    if request.kind == mrUp:
      if isApplied: result.skipped.add target
      else: selected.add (target, mdUp)
    else:
      if not isApplied: result.skipped.add target
      else: selected.add (target, mdDown)
  of mrStatus:
    discard
  for choice in selected:
    checkSelectable(catalog[findDefinition(catalog, choice.version)], choice.direction)
  for choice in selected:
    result.steps.add stepFor(catalog[findDefinition(catalog, choice.version)], choice.direction)
