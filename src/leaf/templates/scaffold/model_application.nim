import leaf
import leaf/app_resources
import leaf/model
import leaf/sqlite as storage
import ./shell
import ./generated/pages
import ../config/[application, routes]
from ../config/database as database_config import nil

proc createApplication*(database: storage.Database = nil,
    resources: HostResources = nil): Application =
  # A passed connection is borrowed; only a connection created here is owned.
  let owned = database == nil
  let connection = if not owned: database
    elif resources != nil: database_config.openApplicationDatabase(resources.dataPath("application.sqlite3"))
    else: database_config.openApplicationDatabase()
  let executionScope: ExecutionScope = proc(body: proc() {.closure.}) =
    withDatabase(connection): body()
  type ShellModel = ref object
    router: ComponentRouter
  let shell = defineComponent[int, ShellModel]("ScaffoldModelShell",
    proc(ctx: MountContext, p: int): ShellModel =
      if owned:
        ctx.onDispose(proc(lifecycle: LifecycleContext) = connection.close())
      ShellModel(router: newComponentRouter(ctx, applicationRoutes(), generatedPages())),
    proc(ctx: ComponentContext, p: int, model: ShellModel): UiDescription =
      renderShell(ctx, model.router))
  componentApplication(component(shell, 0), ApplicationTitle, WindowWidth, WindowHeight,
    executionScope).withNativeTheme(matsuLight)
