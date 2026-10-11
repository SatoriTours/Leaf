## Headless-only isolation probe. Compile with `-d:leafHeadlessOnly` and run
## with `--headless` / `--check` (success) or no arguments (explicit refusal).
import std/os
import leaf

var clicks = 0
proc render(ctx: BuildContext): Node =
  column(@[
    text("count " & $clicks, key = "count"),
    button("go", key = "go", onClick = proc(e: Event) = inc clicks)])

let application = Application(title: "headless probe", width: 320, height: 200,
  render: render)
quit(run(application, commandLineParams()))