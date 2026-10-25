## Compile and stage whole release batches before a no-overwrite hardlink commit.
import std/[os, tempfiles, json, tables, strutils, algorithm, strtabs, monotimes, times, options]
import ./[targets, android_build, android_tools, android_job, android_apk]
import ./[core, project, native_binary, package_files, licenses, archives, checksum, build, process_io]

proc nativeTarget*(): string =
  when defined(linux): "linux"
  elif defined(macosx): "macos"
  elif defined(windows): "windows"
  else: "unsupported"

proc publishArtifacts*(files: seq[(string, string)]) =
  var published: seq[(string, string)]
  try:
    for pair in files:
      checkCancelled()
      createHardlink(pair[0], pair[1])
      published.add(pair)
  except CatchableError:
    for pair in published:
      # A concurrent replacement is not owned by this publication.
      if fileExists(pair[1]) and not symlinkExists(pair[1]) and sameFile(pair[0], pair[1]): removeFile(pair[1])
    raise

proc xml(value: string): string =
  value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")

proc plist(project: Project, hasIcon: bool): string =
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n"
  for (key, value) in [("CFBundleName", project.name), ("CFBundleDisplayName", project.name),
      ("CFBundleIdentifier", project.identifier), ("CFBundleExecutable", project.slug),
      ("CFBundleVersion", project.version), ("CFBundleShortVersionString", project.version),
      ("CFBundlePackageType", "APPL"), ("LSMinimumSystemVersion", "15.0")]:
    result.add("<key>" & key & "</key><string>" & xml(value) & "</string>\n")
  if hasIcon: result.add("<key>CFBundleIconFile</key><string>AppIcon.icns</string>\n")
  result.add("<key>NSHighResolutionCapable</key><true/>\n</dict></plist>\n")

proc archiveFiles(root: string, executable: string): seq[ArchiveEntry] =
  var entries: seq[ArchiveEntry]
  proc visit(path, name: string, depth: int) =
    if depth > 64: fail("release archive exceeds depth 64")
    if entries.len >= 10_000: fail("release archive exceeds 10000 entries")
    if symlinkExists(path): fail("staged release contains a symlink")
    let directory = dirExists(path)
    entries.add(ArchiveEntry(source: path, name: name, directory: directory, executable: path == executable))
    if directory:
      var children: seq[string]
      for kind, child in walkDir(path):
        if children.len + entries.len >= 10_000: fail("release archive exceeds 10000 entries")
        children.add(child)
      children.sort()
      for child in children: visit(child, name & "/" & child.extractFilename, depth + 1)
  visit(root, root.extractFilename, 1)
  entries

proc checkApplication(binary, cwd: string) =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key notin ["LEAF_PROJECT_ROOT", "LEAF_WATCH_TOKEN", "LEAF_WATCH_READY", "LEAF_WATCH_DUMP"]: env[key] = value
  let process = startManaged(binary, @["--check"], cwd, env)
  defer: process.close()
  let start = getMonoTime()
  while not process.poll():
    checkCancelled()
    if (getMonoTime() - start).inMilliseconds > 30_000: fail("packaged application validation timed out")
    sleep(10)
  if process.code != 0: fail("packaged application --check failed (exit " & $process.code & ")\n" & process.output.diagnosticText())

proc packAndroid(project:Project,output,binaryOverride,backend:string):seq[string] =
  discard resolveBuild(project.backend,"android",backend)
  if not project.android.enabled:fail("leaf.json requires platforms.android.entry")
  beginInterruptHandling()
  defer:endInterruptHandling()
  validateOutput(project,output)
  let destination=absolutePath(output)
  createDir(destination)
  let stage=createTempDir(".leaf-pack-","",destination)
  defer:removeDir(stage)
  let name=project.slug & "-" & project.version & "-android.apk"
  let noticeName=project.slug & "-" & project.version & "-android-licenses.zip"
  var publications:seq[(string,string)]
  for artifact in [name,noticeName]:
    for suffix in ["",".sha256"]:
      let path=destination / (artifact & suffix)
      if fileExists(path) or dirExists(path) or symlinkExists(path):
        fail("refusing to overwrite release artifact: " & path)
      publications.add((stage / (artifact & suffix),path))
  var binary=binaryOverride
  if binary.len==0:
    let selected=resolveBuild(project.backend,"android",backend)
    binary=build(project,stage / "application.apk",some(selected))
  else:
    if not isAbsolute(binary):binary=project.root / binary
    binary=checkBinarySource(project,binary)
  # Inspect a private copy; publish exactly those verified bytes.
  let artifact=stage / name
  copyRegular(binary,artifact)
  let tools=discoverAndroidTools(project.android.targetSdk)
  let noticeDirectory=stage / "notices"
  var assets=androidInputs(project)
  assets.add(androidNotices(project,noticeDirectory))
  let job=startAndroidSteps(androidVerificationSteps(project,tools,artifact,stage,assets),directory=stage)
  try:
    while not job.pollAndroid():
      checkCancelled()
      sleep(10)
    if job.code!=0:fail("Android APK validation failed (exit " & $job.code & ")\n" & job.output)
  finally:job.close()
  writeZip(archiveFiles(noticeDirectory / "assets/leaf/licenses",""),stage / noticeName)
  for item in [name,noticeName]:
    writeFile(stage / (item & ".sha256"),sha256File(stage / item) & "  " & item & "\n")
  publishArtifacts(publications)
  @[destination / name,destination / noticeName]

proc pack*(project: Project, target, output: string, binaryOverride = "", backend = ""): seq[string] =
  if target=="android":return packAndroid(project,output,binaryOverride,backend)
  discard resolveBuild(project.backend, target = "windows", backend = backend)
  if target != "windows":
    fail("native packaging not implemented for " & target & "; supported targets: windows, android")
  let targets = @["windows"]
  beginInterruptHandling()
  defer: endInterruptHandling()
  let files = collectFiles(project)
  let implicitLicenses = implicitLicensePaths(project)
  validateOutput(project, output)
  # Child compilation and self-check use different working directories.
  # Resolve once against the caller's cwd so staging paths remain valid there.
  let destination = absolutePath(output)
  createDir(destination)
  let stage = createTempDir(".leaf-pack-", "", destination)
  defer: removeDir(stage)
  var publications: seq[(string, string)]
  for item in targets:
    checkCancelled()
    let settings = project.platforms.getOrDefault(item)
    let bundle = stage / item / (if item == "macos": project.name & ".app" else: project.slug)
    let resources = if item == "macos": bundle / "Contents/Resources" else: bundle
    let appRoot = resources / "app"
    copyFiles(project, files, appRoot)
    writeFile(appRoot / "leaf.json", pretty(%*{"name": project.name, "identifier": project.identifier,
      "version": project.version, "entry": project.entryRelative, "backend": "native",
      "include": project.includedPaths}) & "\n")
    let licenseRoot = resources / "licenses"
    collectLicenses(licenseRoot)
    for relative in implicitLicenses: copyLicenseTree(project, relative, licenseRoot / "application" / relative)
    let executable = if item == "macos": bundle / "Contents/MacOS" / project.slug
      else: bundle / "bin" / (project.slug & (if item == "windows": ".exe" else: ""))
    var binary = if binaryOverride.len > 0: binaryOverride else: settings.binary
    let built = binary.len == 0
    if built:
      if item != nativeTarget(): fail("provide a native application binary for foreign target " & item)
      let staged = readProject(appRoot)
      let job = startBuild(staged, stage / ("application-" & item).addFileExt(ExeExt), stage / ("cache-" & item), isolatedConfig = true)
      try:
        while not job.pollBuild():
          checkCancelled()
          sleep(10)
        if job.code != 0: fail("Nim release build failed\n" & job.output)
        binary = job.binary
      finally: job.close()
    else:
      if not isAbsolute(binary): binary = absolutePath(project.root / binary)
      binary = checkBinarySource(project, binary)
    let architecture = nativeBinary(binary, item)
    if architecture != "x86_64": fail("native Windows packaging requires an x86_64 application")
    copyRegular(binary, executable)
    when defined(posix): setFilePermissions(executable, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    if settings.icon.len > 0:
      let icon = checkSource(project.root, settings.icon)
      if not fileExists(icon): fail("application icon must be a regular file")
      if item == "macos" and not settings.icon.endsWith(".icns"): fail("macOS application icon must be .icns")
      let destination = if item == "macos": resources / "AppIcon.icns" else: resources / "resources" / icon.extractFilename
      copyRegular(icon, destination)
    if item == "macos":
      writeFile(bundle / "Contents/Info.plist", plist(project, settings.icon.len > 0))
      writeFile(bundle / "Contents/PkgInfo", "APPL????")
    writeFile(resources / "README.txt", "Native Nim application: " & project.name & " " & project.version & "\n" &
      "Executable: " & (if item == "macos": "../MacOS/" else: "bin/") & executable.extractFilename & "\n" &
      "Assets are resolved relative to the executable; working directory is unrestricted.\n" &
      "Desktop uses Windows system-native controls; no rendering bridge is bundled.\n" &
      "Headless --check and --headless require no display. See licenses/inventory.json.\n" &
      "Application signing/notarization is a separate release step.\n")
    if built: checkApplication(executable, stage)
    let name = project.slug & "-" & project.version & "-" & item & "-" & architecture & (if item == "linux": ".tar.gz" else: ".zip")
    let artifact = stage / name
    let entries = archiveFiles(bundle, executable)
    if item == "linux": writeTarGzip(entries, artifact)
    else: writeZip(entries, artifact)
    writeFile(artifact & ".sha256", sha256File(artifact) & "  " & name & "\n")
    let published = destination / name
    publications.add((artifact, published)); publications.add((artifact & ".sha256", published & ".sha256"))
    result.add(published)
  for pair in publications:
    if symlinkExists(pair[1]) or fileExists(pair[1]) or dirExists(pair[1]): fail("refusing to overwrite release artifact: " & pair[1])
  publishArtifacts(publications)
