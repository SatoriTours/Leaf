import leaf
import leaf/model
import leaf/sqlite as storage
import ./shell
import ./generated/pages
import ../config/[application, routes]
from ../config/database as database_config import nil

proc createApplication*(database: storage.Database = nil): Application =
  let connection = if database == nil: database_config.openApplicationDatabase() else: database
  let executionScope: ExecutionScope = proc(body: proc() {.closure.}) =
    withDatabase(connection): body()
  type ShellModel = ref object
    router: ComponentRouter
  let shell = defineComponent[int, ShellModel]("ScaffoldModelShell",
    proc(ctx: MountContext, p: int): ShellModel =
      ShellModel(router: newComponentRouter(ctx, applicationRoutes(), generatedPages())),
    proc(ctx: ComponentContext, p: int, model: ShellModel): UiDescription =
      renderShell(ctx, model.router))
  componentApplication(component(shell, 0), ApplicationTitle, WindowWidth, WindowHeight,
    executionScope)
