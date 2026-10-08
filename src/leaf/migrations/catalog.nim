## Compile-time migration discovery. Validates the restricted Nim migration
## protocol before import, embeds legacy SQL bytes, generates valid-named
## wrapper modules under the project target (Nim 2.2.6 cannot import numeric
## module names) and emits the catalog proc.
import std/[compilesettings, macros, os, strutils]
import ./files
import ./types
import ./fingerprint

proc encode(value: string): string = $value.len & ":" & value

proc sqlBasename(path: string): string =
  result = extractFilename(path)
  if result.endsWith(".up.sql"):
    result = result[0 ..< result.len - ".up.sql".len]
  elif result.endsWith(".sql"):
    result = result[0 ..< result.len - ".sql".len]

proc sqlDefinition(file: MigrationFile): MigrationDefinition =
  let upBytes = readFile(file.upPath)
  let hasDown = file.downPath.len > 0 and fileExists(file.downPath)
  let downBytes = if hasDown: readFile(file.downPath) else: ""
  var source = "leaf-migration-sql-v1\nup=" & encode(upBytes) & "\n"
  if hasDown: source.add "down=" & encode(downBytes) else: source.add "down=absent"
  MigrationDefinition(
    version: file.version, name: sqlBasename(file.upPath),
    sourcePath: file.upPath, sourceChecksum: sha256Text(source),
    format: mfSqlV1, upOps: @[], downOps: @[],
    legacyUp: upBytes, legacyDown: downBytes, hasDown: hasDown, pending: false)

proc catalogInputFingerprint*(directory: string): string =
  ## Sorted name/content fingerprint for build invalidation. Relative file names
  ## and bytes only, so the result survives SDK relocation.
  let files = scanMigrationFiles(directory)
  var canonical = "leaf-migration-catalog-v1\n"
  for file in files:
    canonical.add "version=" & $file.version & " name=" & encode(file.name) &
      " format=" & $file.format & "\n"
    canonical.add "up=" & sha256Text(readFile(file.upPath)) & "\n"
    if file.format == mfSqlV1:
      if file.downPath.len > 0:
        canonical.add "down=" & sha256Text(readFile(file.downPath)) & "\n"
      else:
        canonical.add "down=absent\n"
  sha256Text(canonical)

proc validateNimProtocol(path: string, report: NimNode) =
  ## Parse only; nothing from the migration file is executed before this check.
  var statements: NimNode
  try:
    statements = parseStmt(readFile(path))
  except CatchableError as failure:
    error("cannot parse migration " & path & ": " & failure.msg, report)
  var imports = 0
  var migrations = 0
  var sawMigration = false
  for statement in statements:
    case statement.kind
    of nnkCommentStmt: discard
    of nnkImportStmt:
      if sawMigration:
        error("import must precede the migration declaration: " & path, report)
      var valid = false
      if statement.len == 1:
        let module = statement[0]
        if module.kind == nnkInfix and module.len == 3 and
            module[0].kind == nnkIdent and module[0].strVal == "/" and
            module[1].kind == nnkIdent and module[1].strVal == "leaf" and
            module[2].kind == nnkIdent and module[2].strVal == "migrations":
          valid = true
        elif module.kind in {nnkStrLit, nnkRStrLit} and
            module.strVal in ["leaf/migrations", "leaf/migrations.nim"]:
          valid = true
      if not valid:
        error("migration may only import leaf/migrations: " & path, report)
      inc imports
    of nnkCommand, nnkCall:
      if statement.len >= 2 and statement[0].kind == nnkIdent and
          statement[0].strVal == "migration":
        inc migrations
        sawMigration = true
      else:
        error("unexpected top-level statement in migration: " & path, report)
    else:
      error("unexpected top-level statement in migration: " & path, report)
  if imports != 1:
    error("migration must import leaf/migrations exactly once: " & path, report)
  if migrations != 1:
    error("migration must declare exactly one migration: " & path, report)

proc artifactDirectory(projectRoot, nimcache: string): string =
  ## Standard `db/catalog.nim` maps to `<project>/target`, never `db/target`.
  ## The nimcache-derived subdirectory isolates concurrent builds.
  result = projectRoot / "target" / "leaf-migrations"
  if nimcache.len > 0:
    result = result / sha256Text(nimcache)[0 ..< 16]

proc rejectSymlinkAncestors(projectRoot, relative: string, report: NimNode) =
  var path = projectRoot
  for part in relative.split('/'):
    path = path / part
    if pathIsSymlink(path):
      error("generated migration artifacts cannot escape through a symbolic link: " &
        path, report)

macro discoverMigrations*(relativeDir: static[string], procName: untyped): untyped =
  ## Emit `proc <procName>(): seq[MigrationDefinition]` for the migrations in
  ## `relativeDir`, resolved against this source file (never the cwd).
  if procName.kind != nnkIdent:
    error("discoverMigrations expects a plain proc name", procName)
  let callerFile = procName.lineInfoObj.filename
  var callerDir = callerFile.parentDir
  if callerDir.len == 0: callerDir = "."
  if extractFilename(callerDir) != "db":
    error("discoverMigrations expects the catalog at <project>/db/catalog.nim, got " &
      callerFile, procName)
  let directory = normalizedPath(callerDir / relativeDir)
  var files: seq[MigrationFile]
  try:
    files = scanMigrationFiles(directory)
  except MigrationError as failure:
    error(failure.msg, procName)
  for file in files:
    if file.format == mfNimV1:
      validateNimProtocol(file.sourcePath, procName)

  var projectRoot = callerDir.parentDir
  if projectRoot.len == 0: projectRoot = "."
  let artifactDir = artifactDirectory(projectRoot,
    querySetting(SingleValueSetting.nimcacheDir))
  rejectSymlinkAncestors(projectRoot, relativePath(artifactDir, projectRoot).replace('\\', '/'),
    procName)

  result = newStmtList()
  var items = nnkBracket.newTree()
  var wrapperIndex = 0
  for file in files:
    if file.format == mfNimV1:
      let wrapperName = "leaf_migration_" & $file.version & "_" & file.name & ".nim"
      let wrapperPath = artifactDir / wrapperName
      if pathIsSymlink(wrapperPath):
        error("generated migration wrapper cannot be a symbolic link: " & wrapperPath,
          procName)
      let includeTarget = relativePath(file.sourcePath, artifactDir).replace('\\', '/')
      let content = "include \"" & includeTarget & "\"\n"
      if not fileExists(wrapperPath) or readFile(wrapperPath) != content:
        createDir(artifactDir)
        writeFile(wrapperPath, content)
      let alias = "leafMigration" & $wrapperIndex
      var importPath = relativePath(wrapperPath, callerDir).replace('\\', '/')
      if importPath.endsWith(".nim"): importPath = importPath[0 ..< importPath.len - 4]
      let importNode = nnkImportStmt.newTree(
        nnkInfix.newTree(ident"as", newLit(importPath), ident(alias)))
      # The import is resolved against the line info of the node, so every child
      # must point at the catalog file, not at this macro-definition module.
      importNode.copyLineInfo(procName)
      for child in importNode:
        child.copyLineInfo(procName)
        for grandchild in child:
          grandchild.copyLineInfo(procName)
      result.add importNode
      items.add nnkDotExpr.newTree(ident(alias), ident"migrationDefinition")
    else:
      items.add newLit(sqlDefinition(file))
    inc wrapperIndex
  var procDef = parseStmt("proc " & procName.strVal &
    "*(): seq[MigrationDefinition] =\n  discard")[0]
  procDef[6] = nnkStmtList.newTree(nnkPrefix.newTree(ident"@", items))
  procDef.copyLineInfo(procName)
  result.add procDef
