import std/[options, sequtils, unittest]
import leaf/migrations

proc createTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moCreateTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc dropTableOp(table: string): SchemaOperation =
  SchemaOperation(kind: moDropTable,
    tableSpec: TableSpec(name: table, hasId: true), tableDefinitionProvided: true)

proc nimDefinition(version: int64, name: string, pending = false): MigrationDefinition =
  if pending:
    MigrationDefinition(version: version, name: name, sourcePath: name & ".nim",
      sourceChecksum: "source-" & name, format: mfNimV1, hasDown: false, pending: true)
  else:
    MigrationDefinition(version: version, name: name, sourcePath: name & ".nim",
      sourceChecksum: "source-" & name, format: mfNimV1,
      upOps: @[createTableOp(name)], downOps: @[dropTableOp(name)], hasDown: true)

proc nimRecord(definition: MigrationDefinition): MigrationRecord =
  MigrationRecord(version: definition.version, name: definition.name, sql: "generated",
    format: "nim-v1", sourceChecksum: definition.sourceChecksum,
    operationsChecksum: operationsFingerprint(definition),
    downChecksum: downFingerprint(definition))

proc sqlDefinition(version: int64, basename, up, down: string): MigrationDefinition =
  MigrationDefinition(version: version, name: basename, sourcePath: basename & ".up.sql",
    sourceChecksum: "sql-source-" & basename, format: mfSqlV1,
    legacyUp: up, legacyDown: down, hasDown: down.len > 0)

proc sqlRecord(definition: MigrationDefinition): MigrationRecord =
  MigrationRecord(version: definition.version, name: definition.name, sql: definition.legacyUp,
    format: "sql-v1", sourceChecksum: definition.sourceChecksum,
    operationsChecksum: operationsFingerprint(definition),
    downChecksum: downFingerprint(definition))

let one = nimDefinition(1, "one")
let two = nimDefinition(2, "two")
let three = nimDefinition(3, "three")
let catalog = @[one, two, three]
let history = @[nimRecord(one), nimRecord(three)]

suite "pure migration planner":
  test "pending is a set difference rather than maximum version":
    let plan = planMigrations(catalog, history, MigrationRequest(kind: mrMigrate))
    check plan.steps.mapIt((it.version, it.direction)) == @[(2'i64, mdUp)]
    check plan.skipped.len == 0

  test "forward and rollback default to one step":
    check MigrationRequest(kind: mrRollback).steps == 1
    check MigrationRequest(kind: mrForward, steps: 0).steps == 0
    check planMigrations(catalog, history, MigrationRequest(kind: mrForward)).steps.mapIt(
      (it.version, it.direction)) == @[(2'i64, mdUp)]
    check planMigrations(catalog, history, MigrationRequest(kind: mrRollback)).steps.mapIt(
      (it.version, it.direction)) == @[(3'i64, mdDown)]

  test "migrate target converges the applied set":
    let to2 = planMigrations(catalog, history, MigrationRequest(kind: mrMigrate, target: some(2'i64)))
    check to2.steps.mapIt((it.version, it.direction)) == @[(3'i64, mdDown), (2'i64, mdUp)]
    let to0 = planMigrations(catalog, history, MigrationRequest(kind: mrMigrate, target: some(0'i64)))
    check to0.steps.mapIt((it.version, it.direction)) == @[(3'i64, mdDown), (1'i64, mdDown)]
    let to1 = planMigrations(catalog, history, MigrationRequest(kind: mrMigrate, target: some(1'i64)))
    check to1.steps.mapIt((it.version, it.direction)) == @[(3'i64, mdDown)]

  test "steps cap at the available count and invalid steps reject":
    check planMigrations(catalog, history, MigrationRequest(kind: mrRollback, steps: 5)).steps.len == 2
    check planMigrations(catalog, history, MigrationRequest(kind: mrForward, steps: 9)).steps.len == 1
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrRollback, steps: 0))
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrRollback, steps: -1))
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrForward, steps: 0))

  test "up and down no-op targets are explicit skips":
    let upApplied = planMigrations(catalog, history, MigrationRequest(kind: mrUp, target: some(1'i64)))
    check upApplied.steps.len == 0
    check upApplied.skipped == @[1'i64]
    let downPending = planMigrations(catalog, history, MigrationRequest(kind: mrDown, target: some(2'i64)))
    check downPending.steps.len == 0
    check downPending.skipped == @[2'i64]
    let downApplied = planMigrations(catalog, history, MigrationRequest(kind: mrDown, target: some(3'i64)))
    check downApplied.steps.mapIt((it.version, it.direction)) == @[(3'i64, mdDown)]
    let upPending = planMigrations(catalog, history, MigrationRequest(kind: mrUp, target: some(2'i64)))
    check upPending.steps.mapIt((it.version, it.direction)) == @[(2'i64, mdUp)]

  test "unknown or invalid targets reject":
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrMigrate, target: some(9'i64)))
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrMigrate, target: some(-1'i64)))
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrUp, target: some(0'i64)))
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrUp))
    expect MigrationError:
      discard planMigrations(catalog, history, MigrationRequest(kind: mrDown, target: some(9'i64)))

  test "full history preflight precedes even a no-op target":
    var modified = history
    modified[0].sourceChecksum = "changed"
    expect MigrationError:
      discard planMigrations(catalog, modified, MigrationRequest(kind: mrUp, target: some(1'i64)))
    var missing = @[nimRecord(one), nimRecord(three)]
    missing[1].version = 9
    expect MigrationError:
      discard planMigrations(catalog, missing, MigrationRequest(kind: mrUp, target: some(1'i64)))
    var unknown = @[nimRecord(one), nimRecord(three)]
    unknown[0].format = "future-v9"
    expect MigrationError:
      discard planMigrations(catalog, unknown, MigrationRequest(kind: mrUp, target: some(1'i64)))
    var brokenDown = @[nimRecord(one), nimRecord(three)]
    brokenDown[0].downChecksum = "changed"
    expect MigrationError:
      discard planMigrations(catalog, brokenDown, MigrationRequest(kind: mrUp, target: some(1'i64)))
    # status reports rather than raising
    check planMigrations(catalog, modified, MigrationRequest(kind: mrStatus)).steps.len == 0
    check planMigrations(catalog, modified, MigrationRequest(kind: mrStatus)).skipped.len == 0

  test "all selected directions are preflighted before any plan":
    let noDown = MigrationDefinition(version: 1, name: "one", sourcePath: "one.nim",
      sourceChecksum: "source-one", format: mfNimV1,
      upOps: @[createTableOp("one")], hasDown: false)
    let noDownRecord = MigrationRecord(version: 1, name: "one", sql: "generated",
      format: "nim-v1", sourceChecksum: "source-one",
      operationsChecksum: operationsFingerprint(noDown), downChecksum: "")
    expect MigrationError:
      discard planMigrations(@[noDown, three], @[noDownRecord, nimRecord(three)],
        MigrationRequest(kind: mrMigrate, target: some(0'i64)))
    let pendingTwo = nimDefinition(2, "two", pending = true)
    expect MigrationError:
      discard planMigrations(@[one, pendingTwo], @[nimRecord(one)],
        MigrationRequest(kind: mrMigrate))

  test "catalog identity duplicates reject":
    expect MigrationError:
      discard planMigrations(@[one, nimDefinition(1, "other")], @[],
        MigrationRequest(kind: mrMigrate))
    expect MigrationError:
      discard planMigrations(@[sqlDefinition(1, "001_create_tasks", "UP", "DOWN"),
        sqlDefinition(2, "002_create_tasks", "UP", "DOWN")], @[],
        MigrationRequest(kind: mrMigrate))
    expect MigrationError:
      discard planMigrations(@[sqlDefinition(2, "001_create_tasks", "UP", "DOWN")], @[],
        MigrationRequest(kind: mrMigrate))

  test "insertion order does not change the plan":
    let shuffled = @[three, one, two]
    check planMigrations(shuffled, history, MigrationRequest(kind: mrMigrate)).steps ==
      planMigrations(catalog, history, MigrationRequest(kind: mrMigrate)).steps

  test "statements come from the selected direction":
    let upPlan = planMigrations(catalog, history, MigrationRequest(kind: mrForward))
    check upPlan.steps[0].statements == renderStatements(two.upOps)
    check upPlan.steps[0].name == "two"
    check upPlan.steps[0].sourcePath == "two.nim"
    let downPlan = planMigrations(catalog, history, MigrationRequest(kind: mrRollback))
    check downPlan.steps[0].statements == renderStatements(three.downOps)
    check downPlan.steps[0].direction == mdDown

  test "SQL descriptors use raw legacy SQL for both directions":
    let descriptor = sqlDefinition(1, "001_create_tasks", "CREATE TABLE t (id INTEGER);",
      "DROP TABLE t;")
    let plan = planMigrations(@[descriptor], @[sqlRecord(descriptor)],
      MigrationRequest(kind: mrDown, target: some(1'i64)))
    check plan.steps[0].statements == @["DROP TABLE t;"]
    let pendingPlan = planMigrations(@[descriptor], @[],
      MigrationRequest(kind: mrMigrate))
    check pendingPlan.steps[0].statements == @["CREATE TABLE t (id INTEGER);"]

  test "status plans no execution":
    let status = planMigrations(catalog, history, MigrationRequest(kind: mrStatus))
    check status.steps.len == 0
    check status.skipped.len == 0
