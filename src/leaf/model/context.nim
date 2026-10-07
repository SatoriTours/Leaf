## Synchronous, thread-local connection scopes. Never hold a scope across await.
import ../sqlite
import ./errors

type ModelContext* = ref object
  database*: Database
  transactionDepth*: int
  rollingBack*: bool

var activeContext {.threadvar.}: ModelContext

proc currentContext*(): ModelContext =
  if activeContext == nil:
    raise newException(DatabaseContextError,
      "model operation requires an application callback or withDatabase(db) scope")
  activeContext.database.requireUsable()
  activeContext

proc currentDatabase*(): Database = currentContext().database

proc enterDatabase*(db: Database): ModelContext =
  db.requireUsable()
  result = activeContext
  if activeContext != nil and activeContext.database != db and
      (activeContext.transactionDepth > 0 or activeContext.rollingBack):
    raise newException(ModelUsageError, "cannot switch database during an active transaction")
  if activeContext == nil or activeContext.database != db:
    activeContext = ModelContext(database: db)

proc leaveDatabase*(previous: ModelContext) = activeContext = previous

template withDatabase*(db: Database, body: untyped): untyped =
  block:
    let previousContext = enterDatabase(db)
    try:
      body
    finally:
      leaveDatabase(previousContext)
