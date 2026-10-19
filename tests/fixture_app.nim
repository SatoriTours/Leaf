## Test-only managed fixture: a real component root whose render builds a pure
## Node description. Tests that mutate plain fixture state call refreshDispatch
## to request an explicit managed root refresh; no legacy execution engine.
import leaf
export leaf

type FixtureBuild* = proc(): Node {.closure.}

let FixtureRoot = defineComponent[FixtureBuild, int]("TestFixtureRoot",
  proc(ctx: MountContext, build: FixtureBuild): int = 0,
  proc(ctx: ComponentContext, build: FixtureBuild, m: int): UiDescription =
    host(build()))

proc fixtureApplication*(build: FixtureBuild, title = "fixture",
    width = 640, height = 480,
    executionScope: ExecutionScope = nil): Application =
  componentApplication(component(FixtureRoot, build), title, width, height,
    executionScope)

proc dispatchRefresh*(runtime: Runtime, key: string, event: Event): bool =
  ## Explicit fixture refresh after an accepted event; rejected events raise and
  ## keep the previous root exactly as the managed transaction requires.
  if runtime.find(key).node.disabled: return false
  discard runtime.dispatch(key, event)
  discard runtime.refresh()
  true
