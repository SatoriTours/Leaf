import std/[unittest, json, os, tempfiles]
import leaf
import leaf/diagnostics

proc app(render: RenderProc): Application =
  Application(title: "提交门", width: 640, height: 480, render: render)

suite "Runtime candidate commit gate and accepted revision":
  test "commit before callback publication":
    var clicks = 0
    var commits = 0
    var installedWithNil = false
    var acceptedText, candidateText: string

    proc render(ctx: BuildContext): Node =
      column(@[
        text($clicks, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc clicks)])

    let runtime = newRuntime(app(render))
    proc committer(accepted: Runtime, candidate: Runtime) =
      inc commits
      if accepted == nil:
        installedWithNil = true
        check candidate.find("count").node.text == "0"
        return
      acceptedText = accepted.find("count").node.text
      candidateText = candidate.find("count").node.text

    let revisionBeforeInstall = runtime.acceptedRevision
    runtime.setCommitter(committer)
    check installedWithNil
    check commits == 1
    check runtime.acceptedRevision == revisionBeforeInstall
    check runtime.find("count").node.text == "0"
    check runtime.dispatch("go", Event(kind: click))
    check commits == 2
    check acceptedText == "0"
    check candidateText == "1"
    check runtime.acceptedRevision == revisionBeforeInstall + 1

  test "failed commit retains callbacks and caches":
    var clicks = 0
    var failCommit = false

    proc render(ctx: BuildContext): Node =
      column(@[
        text($clicks, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc clicks)])

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if failCommit: raise newException(UiError, "backend rejected"))
    let revisionBefore = runtime.acceptedRevision
    let before = runtime.snapshot.toJson()
    failCommit = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check runtime.find("count").node.text == "0"
    check runtime.snapshot.toJson() == before
    check runtime.acceptedRevision == revisionBefore
    # The old callback and accepted tree stay usable after a rejected commit.
    failCommit = false
    check runtime.dispatch("go", Event(kind: click))
    check runtime.find("count").node.text == "2"
    check runtime.acceptedRevision == revisionBefore + 1

  test "business state is not rolled back":
    var value = "a"
    var failCommit = false

    proc render(ctx: BuildContext): Node =
      input(value, key = "field", onChange = proc(e: Event) =
        value = e.value)

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if failCommit: raise newException(UiError, "no backend"))
    failCommit = true
    expect UiError:
      discard runtime.dispatch("field", Event(kind: change, value: "b"))
    check value == "b"
    check runtime.find("field").node.text == "a"
    failCommit = false
    check runtime.dispatch("field", Event(kind: change, value: "c"))
    check value == "c"
    check runtime.find("field").node.text == "c"

  test "viewport commit failure is isolated":
    var failCommit = false

    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a", "b", "c"],
        proc(index: int): Node = text("row " & $index, key = "row"))])

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if failCommit: raise newException(UiError, "list rejected"))
    check runtime.materialize("items", 0, 2).len == 2
    let before = runtime.snapshot.toJson()
    let builtBefore = runtime.stats.builtItems
    check runtime.find("items").children.len == 2
    failCommit = true
    expect UiError:
      discard runtime.materialize("items", 0, 3)
    check runtime.snapshot.toJson() == before
    check runtime.stats.builtItems == builtBefore
    check runtime.find("items").children.len == 2

  test "preparer materializes without recursive commit":
    var selected = 0
    var commits = 0
    var candidateRows = -1

    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("items", @["a", "b", "c"],
          proc(index: int): Node = text("row " & $index, key = "row")),
        button("go", key = "go", onClick = proc(e: Event) = inc selected)])

    let runtime = newRuntime(app(render))
    runtime.setPreparer(proc(candidate: Runtime) =
      discard candidate.materialize("items", 0, 2))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if accepted != nil:
        inc commits
        candidateRows = candidate.find("items").children.len)
    check runtime.dispatch("go", Event(kind: click))
    check selected == 1
    check commits == 1
    check candidateRows == 2
    check runtime.find("items").children.len == 2

  test "candidate cannot dispatch business callbacks":
    var clicks = 0
    var rejected = 0

    proc render(ctx: BuildContext): Node =
      button("go", key = "go", onClick = proc(e: Event) = inc clicks)

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if accepted == nil: return
      try:
        discard candidate.dispatch("go", Event(kind: click))
      except UiError:
        inc rejected
      try:
        discard candidate.refresh()
      except UiError:
        inc rejected)
    check runtime.dispatch("go", Event(kind: click))
    check rejected == 2
    check clicks == 1

  test "frozen runtime rejects direct business dispatch":
    var clicks = 0

    proc render(ctx: BuildContext): Node =
      button("go", key = "go", onClick = proc(e: Event) = inc clicks)

    let runtime = newRuntime(app(render))
    runtime.freezeEvents("backend restore failed")
    check runtime.eventsFrozen
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check clicks == 0

  test "committer install does not render and cannot be replaced":
    var renders = 0

    proc render(ctx: BuildContext): Node =
      inc renders
      text("x", key = "x")

    let runtime = newRuntime(app(render))
    let rendersBefore = renders
    let revisionBefore = runtime.acceptedRevision
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) = discard)
    check renders == rendersBefore
    check runtime.acceptedRevision == revisionBefore
    expect UiError:
      runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) = discard)
    runtime.setCommitter(nil)
    check renders == rendersBefore
    check runtime.acceptedRevision == revisionBefore

  test "postcommit diagnostics failure does not undo acceptance":
    var clicks = 0

    proc render(ctx: BuildContext): Node =
      column(@[
        text($clicks, key = "count"),
        button("go", key = "go", onClick = proc(e: Event) = inc clicks)])

    let directory = createTempDir("leaf-commit-diag-", "")
    let diagnostics = newDiagnostics(dumpFile = directory / "tree.json")
    let runtime = newRuntime(app(render), diagnostics = diagnostics)
    removeDir(directory)
    let revisionBefore = runtime.acceptedRevision
    check runtime.dispatch("go", Event(kind: click))
    check runtime.acceptedRevision == revisionBefore + 1
    check runtime.find("count").node.text == "1"
    check clicks == 1
    diagnostics.close()