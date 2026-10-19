import leaf
import leaf/sqlite as storage
import ./shell
import ./generated/pages
import ../config/[application, routes]
from ../config/database as database_config import nil

proc createApplication*(database: storage.Database = nil): Application =
  let connection = if database == nil: database_config.openApplicationDatabase() else: database
  type ShellModel = ref object
    router: ComponentRouter
  let shell = defineComponent[int, ShellModel]("ScaffoldShell",
    proc(ctx: MountContext, p: int): ShellModel =
      ShellModel(router: newComponentRouter(ctx, applicationRoutes(), generatedPages(connection))),
    proc(ctx: ComponentContext, p: int, model: ShellModel): UiDescription =
      renderShell(ctx, model.router))
  componentApplication(component(shell, 0), ApplicationTitle, WindowWidth, WindowHeight)
