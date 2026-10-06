import leaf
import leaf/sqlite as storage
import ./shell
import ./generated/pages
import ../config/[application, routes]
from ../config/database as database_config import nil

proc createApplication*(database: storage.Database = nil): Application =
  let connection = if database == nil: database_config.openApplicationDatabase() else: database
  let router = newRouter(applicationRoutes(), generatedPages(connection))
  proc render(ctx: BuildContext): Node = renderShell(router, ctx)
  Application(title: ApplicationTitle, width: WindowWidth, height: WindowHeight,
    render: render)
