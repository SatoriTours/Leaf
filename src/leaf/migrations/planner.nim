## Pure migration planning: validates the catalog and the complete applied
## history, then selects directions. No database, file or lock access.
import std/[algorithm, options, sets, tables]
import ../core
import ./files
import ./fingerprint
import ./sqlite_adapter
import ./types

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

proc issueFor(record: MigrationRecord, code, message: string): MigrationIssue =
  MigrationIssue(code: code, message: message, file: record.name,
    version: some(record.version))

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
  if record.version <= 0 or record.name.len == 0 or record.sql.len == 0:
    return @[issueFor(record, "corrupt_history", "history row is missing version, name or sql")]
  if record.format notin ["sql-v1", "nim-v1"]:
    return @[issueFor(record, "unknown_history_format",
      "unknown history format: " & record.format)]
  let index = findDefinition(catalog, record.version)
  if index < 0:
    return @[issueFor(record, "history_missing_file",
      "no migration file for applied version " & $record.version)]
  let definition = catalog[index]
  if definition.pending:
    result.add issueFor(record, "history_modified",
      "applied migration is now a pending template")
  if record.name != definition.name:
    result.add issueFor(record, "history_name_modified", "applied migration name changed: " &
      record.name & " -> " & definition.name)
  if definition.format == mfNimV1:
    if record.sourceChecksum.len == 0 or record.operationsChecksum.len == 0 or
        (definition.hasDown and record.downChecksum.len == 0):
      result.add issueFor(record, "history_missing_fingerprint",
        "Nim history row is missing recorded fingerprints")
    else:
      if record.sourceChecksum != definition.sourceChecksum:
        result.add issueFor(record, "history_source_modified", "applied migration source changed")
      if record.operationsChecksum != operationsFingerprint(definition):
        result.add issueFor(record, "history_operations_modified",
          "applied migration operations changed")
      if record.downChecksum != downFingerprint(definition):
        result.add issueFor(record, "history_down_modified", "applied migration down changed")
  else:
    if record.sql != definition.legacyUp:
      result.add issueFor(record, "history_sql_modified", "applied SQL changed")
    if record.sourceChecksum.len > 0 and record.sourceChecksum != definition.sourceChecksum:
      result.add issueFor(record, "history_source_modified", "applied SQL source changed")
    if record.operationsChecksum.len > 0 and
        record.operationsChecksum != operationsFingerprint(definition):
      result.add issueFor(record, "history_operations_modified", "applied SQL operations changed")
    if definition.hasDown:
      if record.downChecksum.len == 0:
        result.add issueFor(record, "legacy_unverified_down",
          "down migration was never historically verified")
      elif record.downChecksum != downFingerprint(definition):
        result.add issueFor(record, "history_down_modified", "applied SQL down changed")
    elif record.downChecksum.len > 0:
      result.add issueFor(record, "history_down_modified",
        "history has a down fingerprint but the migration has no down")

proc checkSelectable(definition: MigrationDefinition, direction: MigrationDirection) =
  if definition.pending:
    raise migrationError("pending_migration",
      "migration " & $definition.version & " is a pending template")
  if direction == mdDown:
    if not definition.hasDown:
      raise migrationError("missing_migration_down",
        "migration " & $definition.version & " has no down migration")
    if definition.format == mfSqlV1:
      if definition.legacyDown.len == 0:
        raise migrationError("missing_migration_down",
          "migration " & $definition.version & " has no down SQL")
    elif definition.downOps.len == 0:
      raise migrationError("missing_migration_down",
        "migration " & $definition.version & " has no down operations")

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
    raise migrationError(catalogProblems[0].code, catalogProblems[0].message)
  var applied = initHashSet[int64]()
  for record in history:
    if record.version in applied:
      raise migrationError("corrupt_history", "duplicate applied version " & $record.version)
    applied.incl record.version
    if request.kind != mrStatus:
      for issue in recordIssues(catalog, record):
        if issue.code != "legacy_unverified_down":
          raise migrationError(issue.code, issue.message)
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
        raise migrationError("invalid_migration_target", "migration target must not be negative")
      elif target == 0:
        if appliedVersions.len > 0:
          for index in countdown(appliedVersions.high, 0):
            selected.add (appliedVersions[index], mdDown)
      else:
        if findDefinition(catalog, target) < 0:
          raise migrationError("invalid_migration_target", "no migration with version " & $target)
        if appliedVersions.len > 0:
          for index in countdown(appliedVersions.high, 0):
            if appliedVersions[index] > target:
              selected.add (appliedVersions[index], mdDown)
        for version in pendingVersions:
          if version <= target: selected.add (version, mdUp)
  of mrRollback:
    if request.steps <= 0:
      raise migrationError("invalid_migration_steps", "rollback steps must be positive")
    var taken = 0
    if appliedVersions.len > 0:
      for index in countdown(appliedVersions.high, 0):
        if taken >= request.steps: break
        selected.add (appliedVersions[index], mdDown)
        inc taken
  of mrForward:
    if request.steps <= 0:
      raise migrationError("invalid_migration_steps", "forward steps must be positive")
    var taken = 0
    for version in pendingVersions:
      if taken >= request.steps: break
      selected.add (version, mdUp)
      inc taken
  of mrUp, mrDown:
    if request.target.isNone:
      raise migrationError("invalid_migration_target", "up/down requires a target version")
    let target = request.target.get()
    if target <= 0 or findDefinition(catalog, target) < 0:
      raise migrationError("invalid_migration_target", "no migration with version " & $target)
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
