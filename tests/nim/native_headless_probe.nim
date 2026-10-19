## Headless-only isolation probe. Compile with `-d:leafHeadlessOnly` and run
## with `--headless` / `--check` (success) or no arguments (explicit refusal).
import std/os
import leaf

let Root = defineComponent[int, State[int]]("NativeHeadlessProbeRoot",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, count: State[int]): UiDescription =
    let n = ctx.value(count)
    host(column(@[
      text("count " & $n, key = "count"),
      button("go", key = "go", onClick = proc(e: Event) =
        discard count.update(proc(v: int): int = v + 1))])))

let application = componentApplication(component(Root, 0), "headless probe", 320, 200)
quit(run(application, commandLineParams()))
