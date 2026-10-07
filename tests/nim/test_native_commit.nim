import std/[unittest, json, os, tempfiles]
import leaf
import leaf/[diagnostics, sqlite]
import leaf/model/context

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

  test "first committer install runs inside the application execution scope":
    var depth = 0
    var observed = -1

    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth

    proc render(ctx: BuildContext): Node = text("x", key = "x")

    let runtime = newRuntime(Application(title: "scope", width: 640, height: 480,
      render: render, executionScope: scope))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if accepted == nil: observed = depth)
    check observed == 1
    check depth == 0

  test "first committer install sees the model database context":
    let database = openDatabase(":memory:")
    defer: database.close()
    var observed = false

    proc scope(body: proc() {.closure.}) =
      withDatabase(database): body()

    proc render(ctx: BuildContext): Node = text("x", key = "x")

    let runtime = newRuntime(Application(title: "model", width: 640, height: 480,
      render: render, executionScope: scope))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      if accepted == nil:
        observed = currentDatabase() == database)
    check observed

  test "first committer install candidate carries the accepted revision":
    var candidateRevision = 0'u64
    var proposedRevision = 0'u64

    proc render(ctx: BuildContext): Node = text("x", key = "x")

    let runtime = newRuntime(app(render))
    check runtime.refresh()
    let accepted = runtime.acceptedRevision
    check accepted >= 2
    runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) =
      if acceptedRuntime == nil:
        candidateRevision = candidate.acceptedRevision
        proposedRevision = candidate.proposedRevision)
    check candidateRevision == accepted
    check proposedRevision == 0
    check runtime.acceptedRevision == accepted

  test "successful first install publishes prepared rows":
    var backendRows = -1
    var backendProposed = 0'u64

    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a", "b"],
        proc(index: int): Node = text("row " & $index, key = "row"))])

    let runtime = newRuntime(app(render))
    let accepted = runtime.acceptedRevision
    check runtime.find("items").children.len == 0
    runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) =
      if acceptedRuntime != nil: return
      discard candidate.materialize("items", 0, 1)
      backendRows = candidate.find("items").children.len
      backendProposed = candidate.proposedRevision)
    check backendRows == 1
    check backendProposed == accepted + 1
    check runtime.find("items").children.len == 1
    check runtime.acceptedRevision == backendProposed
    # The published index resolves the prepared row for business events.
    check runtime.find("a").node.text == "row 0"

  test "failed first install leaves the accepted description untouched":
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a", "b"],
        proc(index: int): Node = text("row " & $index, key = "row"))])

    let runtime = newRuntime(app(render))
    let accepted = runtime.acceptedRevision
    let before = runtime.snapshot.toJson()
    expect UiError:
      runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) =
        if acceptedRuntime != nil: return
        discard candidate.materialize("items", 0, 1)
        raise newException(UiError, "mount failed"))
    check runtime.find("items").children.len == 0
    check runtime.snapshot.toJson() == before
    check runtime.acceptedRevision == accepted
    # A failed install does not retain the hook.
    runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) = discard)

  test "candidate preparation during commit keeps the proposed revision stable":
    var proposedBefore, proposedAfter = 0'u64
    var acceptedAfter = 0'u64
    var commits = 0

    proc render(ctx: BuildContext): Node =
      column(@[
        virtualList("items", @["a", "b"],
          proc(index: int): Node = text("row " & $index, key = "row")),
        button("go", key = "go", onClick = proc(e: Event) = discard)])

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) =
      if acceptedRuntime == nil: return
      inc commits
      proposedBefore = candidate.proposedRevision
      discard candidate.materialize("items", 0, 1)
      proposedAfter = candidate.proposedRevision
      acceptedAfter = candidate.acceptedRevision)
    let accepted = runtime.acceptedRevision
    check runtime.dispatch("go", Event(kind: click))
    check commits == 1
    check acceptedAfter == accepted
    check proposedBefore == accepted + 1
    check proposedAfter == proposedBefore
    check runtime.acceptedRevision == accepted + 1
    check runtime.find("items").children.len == 1

  test "no-op preparer does not publish or advance the accepted revision":
    var commits = 0

    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a", "b"],
        proc(index: int): Node = text("row " & $index, key = "row"))])

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) =
      if acceptedRuntime != nil: inc commits)
    let accepted = runtime.acceptedRevision
    let before = runtime.snapshot.toJson()
    runtime.setPreparer(proc(candidate: Runtime) = discard)
    check runtime.acceptedRevision == accepted
    check commits == 0
    check runtime.snapshot.toJson() == before
    runtime.prepare()
    check runtime.acceptedRevision == accepted
    check commits == 0
    runtime.setPreparer(nil)
    check runtime.acceptedRevision == accepted

  test "preparer with prepared rows publishes exactly once":
    var commits = 0

    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a", "b"],
        proc(index: int): Node = text("row " & $index, key = "row"))])

    let runtime = newRuntime(app(render))
    runtime.setCommitter(proc(acceptedRuntime: Runtime, candidate: Runtime) =
      if acceptedRuntime != nil: inc commits)
    let accepted = runtime.acceptedRevision
    runtime.setPreparer(proc(candidate: Runtime) =
      discard candidate.materialize("items", 0, 1))
    check commits == 1
    check runtime.acceptedRevision == accepted + 1
    check runtime.find("items").children.len == 1
  test "committer Scope exit failure retains description indices caches and revision":
    var failExit = false
    var renders, builds, clicks, depth = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if failExit and depth == 0:
        raise newException(UiError, "committer scope exit failed")
    proc render(ctx: BuildContext): Node =
      inc renders
      ctx.cached("component", "stable", proc(): Node =
        column(@[
          virtualList("items", @["a", "b"], proc(index: int): Node =
            inc builds
            text("row " & $index, key = "row")),
          button("go", key = "go", onClick = proc(e: Event) = inc clicks)]))
    let runtime = newRuntime(Application(title: "install", width: 640, height: 480,
      render: render, executionScope: scope))
    let before = runtime.snapshot.toJson()
    let statsBefore = runtime.stats
    let revisionBefore = runtime.acceptedRevision
    failExit = true
    expect UiError:
      discard runtime.installCommitter(proc(accepted: Runtime, candidate: Runtime) =
        discard candidate.materialize("items", 0, 1))
    check runtime.committerOwner == 0
    check runtime.snapshot.toJson() == before
    check runtime.stats == statsBefore
    check runtime.acceptedRevision == revisionBefore
    check not runtime.installingUpdate
    check runtime.find("items").children.len == 0
    expect UiError:
      discard runtime.find("a")
    check renders == 1
    check builds == 1
    failExit = false
    if runtime.committerOwner == 0:
      let token = runtime.installCommitter(proc(accepted: Runtime, candidate: Runtime) = discard)
      check token == 1 # Failed installation did not publish an owner counter.
      discard runtime.materialize("items", 0, 1)
      check builds == 2 # Failed candidate row cache must not be reused.
      check runtime.stats.builtItems == statsBefore.builtItems + 1
      check runtime.dispatch("go", Event(kind: click))
      check clicks == 1
      check runtime.stats.cacheHits == statsBefore.cacheHits + 1

  test "preparer Scope exit failure preserves its previous hook and row state":
    var failExit = false
    var builds, oldPrepares, commits, depth = 0
    proc scope(body: proc() {.closure.}) =
      inc depth
      try: body()
      finally: dec depth
      if failExit and depth == 0:
        raise newException(UiError, "preparer scope exit failed")
    proc render(ctx: BuildContext): Node =
      column(@[virtualList("items", @["a", "b"], proc(index: int): Node =
        inc builds
        text("row " & $index, key = "row"))])
    let runtime = newRuntime(Application(title: "prepare", width: 640, height: 480,
      render: render, executionScope: scope))
    runtime.setCommitter(proc(accepted: Runtime, candidate: Runtime) =
      check depth == 1
      if accepted != nil: inc commits)
    let oldOwner = runtime.installPreparer(proc(candidate: Runtime) = inc oldPrepares)
    let before = runtime.snapshot.toJson()
    let statsBefore = runtime.stats
    let revisionBefore = runtime.acceptedRevision
    failExit = true
    expect UiError:
      discard runtime.installPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("items", 0, 1))
    check runtime.preparerOwner == oldOwner
    check runtime.snapshot.toJson() == before
    check runtime.stats == statsBefore
    check runtime.acceptedRevision == revisionBefore
    check not runtime.installingUpdate
    expect UiError:
      discard runtime.find("a")
    check builds == 1
    check commits == 1
    failExit = false
    runtime.prepare()
    check oldPrepares == 2
    if runtime.preparerOwner == oldOwner:
      let token = runtime.installPreparer(proc(candidate: Runtime) =
        discard candidate.materialize("items", 0, 1))
      check token == oldOwner + 1
      check builds == 2
      check runtime.stats.builtItems == statsBefore.builtItems + 1
      check runtime.acceptedRevision == revisionBefore + 1
      check runtime.find("a").node.text == "row 0"

  test "install guard includes Scope exit and does not publish hooks early":
    var inspectExit = false
    var runtimeRef: Runtime
    var rejected = 0
    proc scope(body: proc() {.closure.}) =
      body()
      if inspectExit:
        inspectExit = false
        check runtimeRef.installingUpdate
        check runtimeRef.committerOwner == 0
        try: discard runtimeRef.dispatch("go", Event(kind: click))
        except UiError: inc rejected
        try: discard runtimeRef.installPreparer(proc(candidate: Runtime) = discard)
        except UiError: inc rejected
    proc render(ctx: BuildContext): Node =
      button("go", key = "go", onClick = proc(e: Event) = discard)
    let runtime = newRuntime(Application(title: "exit guard", width: 640, height: 480,
      render: render, executionScope: scope))
    runtimeRef = runtime
    inspectExit = true
    let token = runtime.installCommitter(proc(accepted: Runtime, candidate: Runtime) = discard)
    check rejected == 2
    check token != 0
    check not runtime.installingUpdate
