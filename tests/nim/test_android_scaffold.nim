import ./cleanup_support
import ./scaffold_headless_support
import std/[unittest, os, json, tempfiles, strutils, monotimes, times]
import leaf/[project, scaffold, core, build, process_io, orm_config]

let base = createTempDir("leaf-android-scaffold-", "")
removeDirectoryOnExit(base)
const
  OwnershipProbe = staticRead("../fixtures/android_scaffold/ownership.nim")
  ResourcesProbe = staticRead("../fixtures/android_scaffold/resources.nim")
  InitProbe = staticRead("../fixtures/android_scaffold/init_resources.nim")
  OldMain = staticRead("../../src/leaf/templates/legacy_init/main.nim")
  OldApp = staticRead("../../src/leaf/templates/legacy_init/app.nim")


proc runGenerated(root, content: string) =
  let sourceRoot = currentSourcePath().parentDir.parentDir.parentDir / "src"
  let probe = root / "tests/android_probe.nim"
  createDir(probe.parentDir)
  writeFile(probe, content)
  var args = @["c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--threads:on", "--mm:orc",
    "--path:" & sourceRoot, "--nimcache:" & root / "target/probe-cache",
    "--out:" & root / "target/probe".addFileExt(ExeExt)]
  args.add(ormCompilerArgs(sourceRoot))
  args.add(probe)
  let child = startManaged(compiler(), args, root)
  defer: child.close()
  let deadline = getMonoTime() + initDuration(seconds=180)
  while not child.poll():
    if getMonoTime() > deadline:
      raise newException(UiError, "generated scaffold probe timed out")
    sleep(10)
  checkpoint child.output.diagnosticText()
  require child.code == 0

suite "generated Android project entries":
  test "init generates an explicit portable mobile entry and shared resources":
    let root = base / "hello-中文 world"
    initProject(root)
    let project = readProject(root)
    check project.android.enabled
    check project.android.entryRelative == "src/mobile.nim"
    check '-' notin project.identifier
    check fileExists(root / "src/mobile.nim")
    check matchesMinimalTemplate(root)
    check "HostResources" in readFile(root / "src/app.nim")
    check "registerAndroidApplication" in readFile(root / "src/mobile.nim")

  test "a modified generated mobile entry refuses init upgrade without writes":
    let root = base / "edited-mobile"
    initProject(root)
    writeFile(root / "src/mobile.nim", "# user entry\n")
    let before = readFile(root / "leaf.json")
    expect UiError: discard generateScaffold(ScaffoldOptions(mode: smApplication), root)
    check readFile(root / "leaf.json") == before
    check not fileExists(root / "main.nim")

  test "full scaffold has a resource factory and migrates untouched init":
    let root = base / "full-scaffold"
    initProject(root)
    let saved = readFile(root / "src/app.nim")
    discard generateScaffold(ScaffoldOptions(mode: smApplication), root)
    let project = readProject(root)
    check project.android.enabled
    check project.android.entryRelative == "mobile.nim"
    check readFile(root / "src/app.nim") == saved
    check "registerAndroidApplication" in readFile(root / "mobile.nim")
    check "HostResources" in readFile(root / "app/application.nim")
    check "dataPath" in readFile(root / "app/application.nim")
    check "onDispose" in readFile(root / "app/application.nim")

  test "Runtime disposal closes an owned database and keeps borrowed connections usable":
    let root = base / "owned scaffold"
    createDir(root)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), root)
    runGenerated(root, OwnershipProbe)

  test "resource factory uses private data and model CRUD survives reopening":
    let root = base / "resource scaffold"
    createDir(root)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), root)
    discard generateScaffold(ScaffoldOptions(mode: smResource, target: "Note", fields: @["title:string"]), root)
    writeHeadlessRows(root)
    runGenerated(root, ResourcesProbe)

  test "init factory renders host resources and leaves the host owner usable":
    let root = base / "init resources"
    initProject(root)
    runGenerated(root, InitProbe)

  test "the exact legacy init still upgrades and retains its entry bytes":
    let root = base / "old-init"
    initProject(root)
    writeFile(root / "leaf.json", pretty(newProjectConfig("old-init", "src/main.nim", @["src", "assets"])) & "\n")
    writeFile(root / "src/main.nim", OldMain)
    writeFile(root / "src/app.nim", OldApp)
    removeFile(root / "src/mobile.nim")
    check matchesMinimalTemplate(root)
    discard generateScaffold(ScaffoldOptions(mode: smApplication), root)
    check readFile(root / "src/main.nim") == OldMain
    check readFile(root / "src/app.nim") == OldApp
    check readProject(root).android.enabled
