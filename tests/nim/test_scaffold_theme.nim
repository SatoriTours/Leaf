## Run the generated artifact. A missing opt-in theme or unsupported inactive
## nav variant must not silently turn a newly scaffolded native app into stock UI.
import ./[cleanup_support, migration_compile_support, scaffold_headless_support]
import std/[unittest, os, tempfiles]
import leaf/scaffold

let base = createTempDir("leaf-scaffold-theme-", "")
removeDirectoryOnExit(base)
let previous = getCurrentDir()
setCurrentDir(base)
try:
  discard generateScaffold(parseScaffoldOptions(@[]), base)
  discard generateScaffold(parseScaffoldOptions(@["Note", "title:string"]), base)
finally: setCurrentDir(previous)
writeHeadlessRows(base)
writeFile(base / "theme_probe.nim", """
import std/[os, tables]
import leaf
import leaf/[styles, backend, host_protocol]
import leaf/backends/win32/capabilities
import config/database as database_config
import app/application
import tests/headless_rows
let db = database_config.openApplicationDatabase(":memory:")
# The probe's main process owns this isolated in-memory database.
let app = createApplication(db)
case paramStr(1)
of "theme":
  doAssert app.nativeTheme == matsuLight
of "navigation":
  let rt = newRuntime(app)
  # Runtime is disposed below after the navigation checks.
  proc checkNav(active: string) =
    for name in ["home", "search", "settings"]:
      let node = rt.find("nav_" & name).node
      let props = normalizeProps(node)
      doAssert checkTypedCapabilities(name, node.kind, props,
        win32Capabilities(matsuLight), strict).len == 0
      doAssert node.attributes["variant"] == (if name == active: "primary" else: "secondary")
  checkNav("home")
  doAssert rt.dispatch("nav_search", Event(kind: click))
  checkNav("search")
  doAssert rt.find("search_query") != nil
  doAssert rt.dispatch("nav_settings", Event(kind: click))
  checkNav("settings")
  doAssert rt.find("hide_completed") != nil
  rt.closeRuntime()
of "resource":
  let rt = newRuntime(app)
  doAssert rt.dispatch("nav_notes", Event(kind: click))
  doAssert rt.dispatch("notes_new", Event(kind: click))
  doAssert rt.dispatch("notes_save", Event(kind: click))
  let error = rt.find("notes_error").node
  doAssert error.text.len > 0
  doAssert error.attributes.getOrDefault("variant") == "danger"
  doAssert rt.dispatch("notes_field_title", Event(kind: change, value: "Saved note"))
  doAssert rt.dispatch("notes_save", Event(kind: click))
  rt.realizeRows()
  doAssert rt.find("notes_title_1").node.text == "Saved note"
  doAssert rt.find("notes_edit_1").node.attributes.getOrDefault("variant") == "secondary"
  doAssert rt.find("notes_delete_1").node.attributes.getOrDefault("variant") == "secondary"
  rt.closeRuntime()
else: doAssert false
db.close()
""")
let compiled = buildProbe(base, "theme_probe.nim", base / "cache",
  extraArgs = @["-d:leafHeadlessOnly"])
suite "generated App theme and native navigation":
  setup:
    if compiled.code != 0: checkpoint compiled.output
    require compiled.code == 0
  test "generated application opts in without changing the framework default":
    let ran = runManagedBounded(compiled.binary, @["theme"], base, seconds=15)
    checkpoint ran.output
    check ran.code == 0
  test "generated resource errors and subordinate actions use the shared semantic skin":
    let ran = runManagedBounded(compiled.binary, @["resource"], base, seconds=15)
    checkpoint ran.output
    check ran.code == 0
  test "route transitions use supported active and inactive native variants":
    let ran = runManagedBounded(compiled.binary, @["navigation"], base, seconds=15)
    checkpoint ran.output
    check ran.code == 0
