## Deterministic SHA-256 fingerprints for migration source and both directions.
## Absolute source paths are diagnostic and never participate in a fingerprint.
import std/[options, strutils]
import ./types
import ../sqlite
import ../vendor/checksums/sha2

proc sha256Text*(content: string): string =
  ## Reuse the vendored SHA-256 without pulling in packaging/network helpers.
  var state = initSha_256()
  state.update(content)
  $state.digest()

proc encode(value: string): string =
  ## Length-prefixed so concatenated names/values cannot be ambiguous.
  $value.len & ":" & value

proc canonicalValue(value: SqlValue): string =
  case value.kind
  of sqlNull: "null"
  of sqlInteger: "int:" & $value.integer
  of sqlFloat: "float:" & cast[uint64](value.number).toHex
  of sqlText: "text:" & encode(value.text)

proc canonicalColumn(column: ColumnSpec): string =
  result = encode(column.name) & " " & $column.kind & " nullable=" & $column.nullable & " "
  if column.defaultValue.isSome:
    result.add "default=" & canonicalValue(column.defaultValue.get())
  else:
    result.add "default=absent"

proc canonicalTable(table: TableSpec): string =
  result = encode(table.name) & " id=" & $table.hasId &
    " autoIncrement=" & $table.autoIncrement & " columns=" & $table.columns.len
  for column in table.columns: result.add " [" & canonicalColumn(column) & "]"

proc canonicalIndex(index: IndexSpec): string =
  result = encode(index.table) & " " & encode(index.name) & " unique=" & $index.unique
  for column in index.columns: result.add " " & encode(column)

proc canonicalOperation(operation: SchemaOperation): string =
  case operation.kind
  of moCreateTable, moDropTable:
    result = $operation.kind & " " & canonicalTable(operation.tableSpec) &
      " provided=" & $operation.tableDefinitionProvided
  of moAddColumn, moRemoveColumn:
    result = $operation.kind & " " & encode(operation.tableName) & " " &
      canonicalColumn(operation.columnSpec) &
      " provided=" & $operation.columnDefinitionProvided
  of moRenameTable:
    result = $operation.kind & " " & encode(operation.oldTableName) & " -> " &
      encode(operation.newTableName)
  of moRenameColumn:
    result = $operation.kind & " " & encode(operation.columnTableName) & " " &
      encode(operation.oldColumnName) & " -> " & encode(operation.newColumnName)
  of moAddIndex, moRemoveIndex:
    result = $operation.kind & " " & canonicalIndex(operation.indexSpec)

proc operationsFingerprint*(definition: MigrationDefinition): string =
  ## Fingerprint of the canonical two-direction plan. Legacy SQL migrations have
  ## no operation lists, so their raw up/down bytes are the plan.
  var canonical = "leaf-migration-operations-v1\n"
  canonical.add "format=" & $definition.format & "\n"
  canonical.add "version=" & $definition.version & "\n"
  canonical.add "name=" & encode(definition.name) & "\n"
  canonical.add "pending=" & $definition.pending & "\n"
  canonical.add "hasDown=" & $definition.hasDown & "\n"
  if definition.format == mfSqlV1:
    canonical.add "legacyUp=" & encode(definition.legacyUp) & "\n"
    canonical.add "legacyDown=" & encode(definition.legacyDown) & "\n"
  canonical.add "up=" & $definition.upOps.len & "\n"
  for operation in definition.upOps: canonical.add canonicalOperation(operation) & "\n"
  canonical.add "down=" & $definition.downOps.len & "\n"
  for operation in definition.downOps: canonical.add canonicalOperation(operation) & "\n"
  sha256Text(canonical)

proc downFingerprint*(definition: MigrationDefinition): string =
  ## Reverse-plan fingerprint. A pending template has no reverse plan yet.
  if not definition.hasDown: return ""
  var canonical = "leaf-migration-down-v1\n"
  if definition.format == mfSqlV1:
    canonical.add "legacyDown=" & encode(definition.legacyDown) & "\n"
  canonical.add "down=" & $definition.downOps.len & "\n"
  for operation in definition.downOps: canonical.add canonicalOperation(operation) & "\n"
  sha256Text(canonical)
