import std/os
import leaf
import leaf/model
import leaf/sqlite
import ../app/application
putEnv("LEAF_DATABASE_PATH", currentSourcePath().parentDir / "owned.sqlite3")
let appValue = createApplication()
var captured: Database
appValue.executionScope(proc() = captured = currentDatabase())
let runtime = newRuntime(appValue)
doAssert captured.query("SELECT COUNT(*) FROM tasks")[0][0].asInt64 == 0
runtime.closeRuntime()
var closed = false
try: captured.requireUsable()
except DatabaseError: closed = true
doAssert closed, "owned connection must close at Runtime disposal"
runtime.closeRuntime()
let borrowed = openDatabase(":memory:")
# Migration belongs to configuration; supplying a connection still requires prepared schema.
import ../config/database as database_config
borrowed.close()
let external = database_config.openApplicationDatabase(":memory:")
let other = newRuntime(createApplication(external))
other.closeRuntime()
doAssert external.query("SELECT COUNT(*) FROM tasks")[0][0].asInt64 == 0
external.close()
echo "generated scaffold ownership: passed"
