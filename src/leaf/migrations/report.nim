## Migration result serialization: one JSON object, truthful nulls, decimal
## version strings, and an exit code contract.
import std/[json, options, sequtils, strutils]
import ./types

proc stepJson(step: MigrationStep): JsonNode =
  result = newJObject()
  result["version"] = %($step.version)
  result["direction"] = %(if step.direction == mdUp: "up" else: "down")
  result["name"] = %step.name
  result["file"] = %step.sourcePath
  result["statements"] = %step.statements

proc issueJson(issue: MigrationIssue): JsonNode =
  result = newJObject()
  result["code"] = %issue.code
  result["message"] = %issue.message
  result["version"] = if issue.version.isSome: %($issue.version.get()) else: newJNull()
  result["file"] = %issue.file
  result["direction"] = if issue.direction.isSome:
      %(if issue.direction.get() == mdUp: "up" else: "down")
    else: newJNull()

proc statusJson(status: MigrationStatus): JsonNode =
  result = newJObject()
  result["version"] = %($status.version)
  result["name"] = %status.name
  result["file"] = %status.file
  result["state"] = %status.state
  result["issues"] = %status.issues.map(issueJson)

proc resultJson*(migration: MigrationResult): JsonNode =
  result = newJObject()
  result["command"] = %migration.command
  result["database"] = %migration.database
  result["dry_run"] = %migration.dryRun
  result["execution_confirmed"] = %migration.executionConfirmed
  result["planned"] = %migration.planned.map(stepJson)
  if migration.executionConfirmed:
    result["executed"] = %migration.executed.map(stepJson)
    result["current_version"] = if migration.currentVersion.isSome:
        %($migration.currentVersion.get()) else: newJNull()
  else:
    # Forced termination: never pretend an empty committed list.
    result["executed"] = newJNull()
    result["current_version"] = newJNull()
  result["skipped"] = %migration.skipped.mapIt($it)
  if migration.executionConfirmed and migration.currentVersion.isSome:
    result["pending_versions"] = %migration.pendingVersions.mapIt($it)
  else:
    result["pending_versions"] = newJNull()
  result["statuses"] = %migration.statuses.map(statusJson)
  result["errors"] = %migration.errors.map(issueJson)

proc resultText*(migration: MigrationResult): string =
  var lines: seq[string]
  lines.add(migration.command & ": " &
    (if migration.database.len > 0: migration.database else: ":memory:"))
  for step in migration.planned:
    lines.add("planned " & (if step.direction == mdUp: "up" else: "down") & " " &
      $step.version & " " & step.name)
  for step in migration.executed:
    lines.add("executed " & (if step.direction == mdUp: "up" else: "down") & " " &
      $step.version & " " & step.name)
  for version in migration.skipped: lines.add("skipped " & $version)
  for error in migration.errors: lines.add("error " & error.code & ": " & error.message)
  lines.add("current version: " &
    (if migration.currentVersion.isSome: $migration.currentVersion.get() else: "unknown"))
  var destructive = false
  for step in migration.planned:
    if step.direction == mdDown: destructive = true
  for step in migration.executed:
    if step.direction == mdDown: destructive = true
  if destructive:
    lines.add("rollback is structural only; deleted data is not restored")
  result = lines.join("\n")

proc resultExitCode*(migration: MigrationResult): int =
  if not migration.executionConfirmed: return 130
  for error in migration.errors:
    if error.code in ["migration_cancelled", "migration_interrupted"]: return 130
  if migration.errors.len > 0: return 1
  0
