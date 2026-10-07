## SQLite connections, bound statements and transactional application migrations.
## Import leaf/sqlite explicitly; applications without storage need no SQLite library.
import std/[os, strutils, algorithm, sets]
import ./sqlite_native as native

type
  DatabaseError* = object of ValueError
    code*, extendedCode*: int
  ConstraintError* = object of DatabaseError
  SqlKind* = enum sqlNull, sqlInteger, sqlFloat, sqlText
  SqlValue* = object
    case kind*: SqlKind
    of sqlNull: discard
    of sqlInteger: integer*: int64
    of sqlFloat: number*: float
    of sqlText: text*: string
  DatabaseHandle = object
    connection: ptr native.SqliteConnection
    ownerThread: int
  Database* = ref DatabaseHandle
  Migration* = object
    version*: int
    name*, sql*: string

proc `=destroy`(db: DatabaseHandle) =
  if db.connection != nil: discard native.closeConnection(db.connection)

proc toSqlValue(value: string): SqlValue = SqlValue(kind: sqlText, text: value)
proc toSqlValue(value: SomeInteger): SqlValue = SqlValue(kind: sqlInteger, integer: int64(value))
proc toSqlValue(value: float): SqlValue = SqlValue(kind: sqlFloat, number: value)
proc toSqlValue(value: bool): SqlValue = toSqlValue(int(value))
template dbValue*(value: typed): SqlValue = toSqlValue(value)
proc asString*(value: SqlValue): string =
  if value.kind != sqlText: raise newException(DatabaseError, "expected SQLite text")
  value.text
proc asInt*(value: SqlValue): int =
  if value.kind != sqlInteger or value.integer < int64(low(int)) or value.integer > int64(high(int)):
    raise newException(DatabaseError, "expected SQLite integer within Nim int range")
  int(value.integer)
proc asInt64*(value: SqlValue): int64 =
  if value.kind != sqlInteger: raise newException(DatabaseError, "expected SQLite integer")
  value.integer
proc asFloat*(value: SqlValue): float =
  case value.kind
  of sqlFloat: value.number
  of sqlInteger: float(value.integer)
  else: raise newException(DatabaseError, "expected SQLite number")
proc asBool*(value: SqlValue): bool = value.asInt != 0

proc requireUsable*(db: Database) =
  if db == nil or db.connection == nil: raise newException(DatabaseError, "database is closed")
  when compileOption("threads"):
    if db.ownerThread != getThreadId():
      raise newException(DatabaseError, "database belongs to another thread")

proc borrowSqliteHandle*(db: Database): pointer =
  ## Internal ORM bridge. The caller borrows this handle and must never close it.
  db.requireUsable()
  cast[pointer](db.connection)

proc raiseSqliteError*(db: Database, detail = "") {.noreturn.} =
  db.requireUsable()
  let code = int(native.errorCode(db.connection))
  let extendedCode = int(native.extendedErrorCode(db.connection))
  let message = "SQLite: " & (if detail.len > 0: detail else: $native.errorMessage(db.connection))
  let error = if code == 19: newException(ConstraintError, message)
    else: newException(DatabaseError, message)
  error.code = code
  error.extendedCode = extendedCode
  raise error

proc check(db: Database, code: cint) =
  if code != 0: db.raiseSqliteError()

proc close*(db: Database) =
  if db != nil and db.connection != nil:
    db.requireUsable()
    db.check(native.closeConnection(db.connection))
    db.connection = nil

proc executeScript*(db: Database, sql: string) =
  db.requireUsable()
  if '\0' in sql: raise newException(DatabaseError, "SQL cannot contain NUL")
  db.check(native.executeScript(db.connection, sql.cstring, nil, nil, nil))

proc openDatabase*(path: string): Database =
  if path.len == 0 or '\0' in path: raise newException(DatabaseError, "invalid database path")
  if path != ":memory:": createDir(absolutePath(path).parentDir)
  result = Database()
  when compileOption("threads"): result.ownerThread = getThreadId()
  # READWRITE | CREATE | FULLMUTEX. Connections are used on their owning UI thread.
  let code = native.openConnection(path.cstring, addr result.connection, 0x10006, nil)
  if code != 0:
    let message = if result.connection == nil: "cannot allocate SQLite connection" else: $native.errorMessage(result.connection)
    result.close()
    raise newException(DatabaseError, "SQLite: " & message)
  try:
    result.check(native.busyTimeout(result.connection, 5000))
    result.executeScript("PRAGMA foreign_keys = ON;")
  except CatchableError:
    result.close()
    raise

proc prepare(db: Database, sql: string, values: openArray[SqlValue]): ptr native.SqliteStatement =
  db.requireUsable()
  if '\0' in sql: raise newException(DatabaseError, "SQL cannot contain NUL")
  var tail: cstring
  db.check(native.prepareStatement(db.connection, sql.cstring, -1, addr result, addr tail))
  try:
    if result == nil or (tail != nil and ($tail).strip.len > 0):
      raise newException(DatabaseError, "expected exactly one SQL statement")
    if int(native.parameterCount(result)) != values.len:
      raise newException(DatabaseError, "SQL parameter count does not match bound values")
    for i, value in values:
      let index = cint(i + 1)
      let code = case value.kind
        of sqlNull: native.bindNull(result, index)
        of sqlInteger: native.bindInteger(result, index, value.integer)
        of sqlFloat: native.bindFloat(result, index, value.number)
        of sqlText:
          if value.text.len > high(cint).int: raise newException(DatabaseError, "SQLite text is too large")
          # SQLITE_TRANSIENT copies Nim-owned text before its lifetime can end.
          native.bindText(result, index, value.text.cstring, cint(value.text.len), cast[pointer](-1))
      db.check(code)
  except CatchableError:
    if result != nil: discard native.finalizeStatement(result)
    raise

proc execute*(db: Database, sql: string, values: openArray[SqlValue] = []): int =
  let statement = db.prepare(sql, values)
  defer: discard native.finalizeStatement(statement)
  let code = native.step(statement)
  if code != 101: db.check(code) # SQLITE_DONE
  int(native.changedRows(db.connection))

proc lastInsertId*(db: Database): int =
  db.requireUsable()
  dbValue(native.insertId(db.connection)).asInt

proc lastInsertId64*(db: Database): int64 =
  db.requireUsable()
  native.insertId(db.connection)

proc query*(db: Database, sql: string, values: openArray[SqlValue] = []): seq[seq[SqlValue]] =
  let statement = db.prepare(sql, values)
  defer: discard native.finalizeStatement(statement)
  while true:
    let code = native.step(statement)
    if code == 101: break
    if code != 100: db.check(code) # SQLITE_ROW
    var row: seq[SqlValue]
    for column in 0..<native.columnCount(statement):
      case native.columnType(statement, column)
      of 1: row.add(dbValue(native.columnInteger(statement, column)))
      of 2: row.add(dbValue(float(native.columnFloat(statement, column))))
      of 3:
        let data = native.columnText(statement, column)
        let size = int(native.columnBytes(statement, column))
        var text = newString(size)
        if size > 0: copyMem(addr text[0], data, size)
        row.add(dbValue(text))
      of 5: row.add(SqlValue(kind: sqlNull))
      else: raise newException(DatabaseError, "SQLite blob values are not supported")
    result.add(row)

proc migrationAuthorizer(context: pointer, action: cint, first, second, database, trigger: cstring): cint {.cdecl.} =
  # SQLITE_TRANSACTION and SQLITE_SAVEPOINT: the runner owns the transaction.
  if action in [22.cint, 32.cint]: 1 else: 0

proc migrate*(db: Database, migrations: openArray[Migration]) =
  ## Pass the complete migration history. Each pending version commits atomically.
  var ordered: seq[Migration]
  var versions: HashSet[int]
  for migration in migrations:
    if migration.version <= 0 or migration.version in versions or
        migration.name.len == 0 or migration.sql.strip.len == 0:
      raise newException(DatabaseError, "invalid or duplicate migration")
    versions.incl(migration.version)
    ordered.add(migration)
  ordered.sort(proc(a, b: Migration): int = cmp(a.version, b.version))
  db.executeScript("CREATE TABLE IF NOT EXISTS leaf_schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL);")
  for row in db.query("SELECT version FROM leaf_schema_migrations"):
    if row[0].asInt notin versions:
      raise newException(DatabaseError, "database contains a migration missing from this application")
  for migration in ordered:
    discard db.execute("BEGIN IMMEDIATE")
    try:
      let applied = db.query("SELECT name, sql FROM leaf_schema_migrations WHERE version = ?", @[dbValue(migration.version)])
      if applied.len > 0:
        if applied[0][0].asString != migration.name or applied[0][1].asString != migration.sql:
          raise newException(DatabaseError, "applied migration was modified: " & migration.name)
      else:
        db.check(native.setAuthorizer(db.connection, migrationAuthorizer, nil))
        try: db.executeScript(migration.sql)
        finally: db.check(native.setAuthorizer(db.connection, nil, nil))
        discard db.execute("INSERT INTO leaf_schema_migrations (version, name, sql) VALUES (?, ?, ?)",
          @[dbValue(migration.version), dbValue(migration.name), dbValue(migration.sql)])
      discard db.execute("COMMIT")
    except CatchableError:
      discard db.execute("ROLLBACK")
      raise
