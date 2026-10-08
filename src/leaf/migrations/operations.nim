## Structural inversion of schema operations. No database access, no Model.
import ./types

proc invertOperation*(operation: SchemaOperation): SchemaOperation =
  case operation.kind
  of moCreateTable:
    SchemaOperation(kind: moDropTable, tableSpec: operation.tableSpec,
      tableDefinitionProvided: true)
  of moDropTable:
    if not operation.tableDefinitionProvided:
      raise migrationError("irreversible_operation",
        "dropTable " & operation.tableSpec.name & " cannot be inverted without its structure")
    SchemaOperation(kind: moCreateTable, tableSpec: operation.tableSpec,
      tableDefinitionProvided: true)
  of moAddColumn:
    SchemaOperation(kind: moRemoveColumn, tableName: operation.tableName,
      columnSpec: operation.columnSpec, columnDefinitionProvided: true)
  of moRemoveColumn:
    if not operation.columnDefinitionProvided:
      raise migrationError("irreversible_operation",
        "removeColumn " & operation.columnSpec.name &
        " cannot be inverted without its original type")
    SchemaOperation(kind: moAddColumn, tableName: operation.tableName,
      columnSpec: operation.columnSpec, columnDefinitionProvided: true)
  of moRenameTable:
    SchemaOperation(kind: moRenameTable, oldTableName: operation.newTableName,
      newTableName: operation.oldTableName)
  of moRenameColumn:
    SchemaOperation(kind: moRenameColumn, columnTableName: operation.columnTableName,
      oldColumnName: operation.newColumnName, newColumnName: operation.oldColumnName)
  of moAddIndex:
    SchemaOperation(kind: moRemoveIndex, indexSpec: operation.indexSpec)
  of moRemoveIndex:
    SchemaOperation(kind: moAddIndex, indexSpec: operation.indexSpec)

proc invertOperations*(operations: openArray[SchemaOperation]): seq[SchemaOperation] =
  ## Inverses run in reverse order, so createTable + addIndex drops the index first.
  if operations.len == 0: return @[]
  result = newSeqOfCap[SchemaOperation](operations.len)
  for index in countdown(operations.high, 0):
    result.add invertOperation(operations[index])
