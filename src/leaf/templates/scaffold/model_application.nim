import leaf
import leaf/model
import leaf/sqlite as storage
import ./shell
import ./generated/pages
import ../config/[application, routes]
from ../config/database as database_config import nil

proc createApplication*(database: storage.Database = nil): Application =
  let connection = if database == nil: database_config.openApplicationDatabase() else: database
  var router: Router
  withDatabase(connection):
    router = newRouter(applicationRoutes(), generatedPages())
  proc scope(body: proc() {.closure.}) =
    withDatabase(connection): body()
  proc render(ctx: BuildContext): Node =
    withDatabase(connection): result = renderShell(router, ctx)
  Application(title: ApplicationTitle, width: WindowWidth, height: WindowHeight,
    render: render, executionScope: scope)
