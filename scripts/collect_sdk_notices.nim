## Collect license/NOTICE texts for the resolved native GPUI dependency graph.
import std/[algorithm, base64, httpclient, json, os, parseopt, sets, strutils, tables]
when defined(ssl): import std/net

type
  LicenseHttpError* = object of CatchableError
    status*: int
  HttpDownloadProc* = proc(url: string, headers: HttpHeaders): string {.closure.}
  LicenseFetchProc* = proc(repository, revision: string): JsonNode {.closure.}
  DownloadProc* = proc(package: JsonNode): JsonNode {.closure.}

var licenseCache = initTable[(string, string), JsonNode]()

proc clearLicenseCache*() = licenseCache.clear()

proc httpDownload(url: string, headers: HttpHeaders): string =
  when defined(ssl):
    # Honor CI's CA bundle while retaining peer certificate verification.
    let context = newContext(verifyMode = CVerifyPeerUseEnvVars)
    let client = newHttpClient(timeout = 30_000, headers = headers, sslContext = context)
  else:
    if url.startsWith("https://"):
      raise newException(ValueError, "HTTPS license downloads require compiling collect_sdk_notices with -d:ssl")
    let client = newHttpClient(timeout = 30_000, headers = headers)
  defer: client.close()
  let response = client.get(url)
  if response.code.int >= 400:
    let error = newException(LicenseHttpError, "HTTP " & $response.code & " for " & url)
    error.status = response.code.int
    raise error
  response.body

proc optional(node: JsonNode, key: string): JsonNode =
  if node.hasKey(key): node[key] else: newJNull()

proc text(node: JsonNode, key: string): string = optional(node, key).getStr()

proc replacementUtf8(value: string): string

proc fetchLicense*(repository, revision: string,
                   get: HttpDownloadProc = httpDownload): JsonNode =
  let key = (repository, revision)
  if licenseCache.hasKey(key): return licenseCache[key].copy()
  let headers = newHttpHeaders({"User-Agent": "Leaf-SDK-license-collector"})
  var texts = newJObject()
  var source = ""
  if repository.startsWith("https://github.com/"):
    let parts = repository["https://github.com/".len .. ^1].split('/')
    if parts.len >= 2 and parts[0].len > 0:
      var name = parts[1].split({'#', '?'})[0]
      if name.endsWith(".git"): name.setLen(name.len - 4)
      if name.len > 0:
        var url = "https://api.github.com/repos/" & parts[0] & "/" & name & "/license"
        if revision.len > 0: url.add("?ref=" & revision)
        let token = getEnv("GH_TOKEN")
        if token.len > 0: headers["Authorization"] = "Bearer " & token
        let response = parseJson(get(url, headers))
        let content = decode(response["content"].getStr())
        if replacementUtf8(content) != content:
          raise newException(ValueError, "upstream license is not UTF-8")
        texts[response["name"].getStr()] = %content
        source = response["download_url"].getStr()
  elif repository.startsWith("https://gitlab.redox-os.org/"):
    source = repository.strip(leading = false, chars = {'/'}) & "/-/raw/" &
      (if revision.len > 0: revision else: "master") & "/LICENSE"
    let content = get(source, headers)
    if replacementUtf8(content) != content:
      raise newException(ValueError, "upstream license is not UTF-8")
    texts["LICENSE"] = %content
  result = %*{"texts": texts, "license_source": source}
  licenseCache[key] = result.copy()

proc defaultFetch(repository, revision: string): JsonNode = fetchLicense(repository, revision)

proc upstream*(package: JsonNode, fetch: LicenseFetchProc = defaultFetch): JsonNode =
  var repository = package.text("repository")
  if repository.len == 0: repository = package.text("homepage")
  repository = repository.replace("http://github.com/", "https://github.com/")
  let vcs = package["manifest_path"].getStr().parentDir / ".cargo_vcs_info.json"
  let revision = if fileExists(vcs): parseFile(vcs)["git"]["sha1"].getStr() else: ""
  try:
    result = fetch(repository, revision)
  except LicenseHttpError as error:
    # Rewritten upstream history: retain the source URL returned for current HEAD.
    if error.status != 404 or revision.len == 0: raise
    result = fetch(repository, "")

proc defaultDownload(package: JsonNode): JsonNode = upstream(package)

proc licenseFilename(path: string): bool =
  if path.splitFile.ext in [".rs", ".png"]: return false
  let name = path.extractFilename.toLowerAscii()
  for prefix in ["license", "licence", "copying", "copyright", "notice"]:
    if name.startsWith(prefix) and
        (name.len == prefix.len or name[prefix.len] in {'-', '_', '.'}): return true

proc replacementUtf8(value: string): string =
  ## Replace malformed UTF-8 byte sequences in crate notice files.
  var index = 0
  while index < value.len:
    let first = ord(value[index])
    if first < 128:
      result.add(value[index])
      inc index
      continue
    let size = if first in 0xC2..0xDF: 2 elif first in 0xE0..0xEF: 3
               elif first in 0xF0..0xF4: 4 else: 0
    if size == 0:
      result.add("\xef\xbf\xbd")
      inc index
      continue
    var consumed = 1
    while consumed < size and index + consumed < value.len:
      let next = ord(value[index + consumed])
      if next notin 0x80..0xBF: break
      if consumed == 1 and ((first == 0xE0 and next < 0xA0) or
          (first == 0xED and next >= 0xA0) or (first == 0xF0 and next < 0x90) or
          (first == 0xF4 and next >= 0x90)): break
      inc consumed
    if consumed == size: result.add(value[index ..< index + size])
    else: result.add("\xef\xbf\xbd")
    index += consumed

proc collect*(metadata, baseline: JsonNode,
              download: DownloadProc = defaultDownload): JsonNode =
  var packages = initTable[string, JsonNode]()
  var nodes = initTable[string, seq[string]]()
  var root = ""
  for package in metadata["packages"]:
    packages[package["id"].getStr()] = package
    if root.len == 0 and package["name"].getStr() == "leaf-gpui": root = package["id"].getStr()
  if root.len == 0: raise newException(ValueError, "leaf-gpui package missing from metadata")
  for node in metadata["resolve"]["nodes"]:
    var dependencies: seq[string]
    for dependency in node["dependencies"]: dependencies.add(dependency.getStr())
    nodes[node["id"].getStr()] = dependencies
  var resolved = initHashSet[string]()
  var pending = @[root]
  while pending.len > 0:
    let current = pending.pop()
    if current in resolved: continue
    resolved.incl(current)
    pending.add(nodes.getOrDefault(current))
  var old = initTable[(string, string), JsonNode]()
  var apache, mit: string
  for package in baseline["packages"]:
    old[(package["name"].getStr(), package["version"].getStr())] = package
    if package.hasKey("texts"):
      for name, value in package["texts"]:
        let content = value.getStr()
        if apache.len == 0 and "apache" in name.toLowerAscii() and "Version 2.0" in content:
          apache = content
        if mit.len == 0 and "mit" in name.toLowerAscii() and
            content.strip(leading = true, trailing = false).startsWith("Permission is hereby granted"):
          mit = content
  var identifiers: seq[string]
  for identifier in resolved: identifiers.add(identifier)
  identifiers.sort(proc(a, b: string): int =
    result = cmp(packages[a]["name"].getStr(), packages[b]["name"].getStr())
    if result == 0: result = cmp(packages[a]["version"].getStr(), packages[b]["version"].getStr()))
  var notices = newJArray()
  for identifier in identifiers:
    let package = packages[identifier]
    if package.text("source").len == 0: continue
    var item = newJObject()
    for key in ["name", "version", "license", "repository", "authors", "source"]:
      item[key] = package.optional(key).copy()
    let name = package["name"].getStr()
    let version = package["version"].getStr()
    item["source_archive"] = %("https://static.crates.io/crates/" & name & "/" & name & "-" & version & ".crate")
    item["texts"] = newJObject()
    if old.hasKey((name, version)) and old[(name, version)].hasKey("texts"):
      item["texts"] = old[(name, version)]["texts"].copy()
    let directory = package["manifest_path"].getStr().parentDir
    var paths: seq[string]
    for path in walkDirRec(directory, yieldFilter = {pcFile, pcLinkToFile}):
      if fileExists(path) and licenseFilename(path): paths.add(path)
    paths.sort()
    for path in paths:
      item["texts"][path.relativePath(directory).replace('\\', '/')] =
        %replacementUtf8(readFile(path).replace("\r\n", "\n").replace("\r", "\n"))
    if item["texts"].len == 0 and "Apache-2.0" in package.text("license") and apache.len > 0:
      item["texts"] = %*{"LICENSE-APACHE-2.0": apache}
      item["selected_license"] = %"Apache-2.0"
    if item["texts"].len == 0:
      try:
        let downloaded = download(package)
        for key, value in downloaded: item[key] = value.copy()
      except LicenseHttpError as error:
        if error.status == 404 and package.text("license") == "MIT" and mit.len > 0:
          item["texts"] = %*{"LICENSE-MIT": mit}
          item["selected_license"] = %"MIT"
        else:
          raise newException(ValueError, "license retrieval failed for " & name & " " & version & ": " & error.msg)
      except CatchableError as error:
        raise newException(ValueError, "license retrieval failed for " & name & " " & version & ": " & error.msg)
    if not item.hasKey("texts") or item["texts"].len == 0:
      raise newException(ValueError, "license material missing: " & name & " " & version)
    notices.add(item)
  result = %*{"gpui_kit": "0.7.0", "packages": notices}

proc main(): int =
  var metadataPath, outputPath: string
  try:
    var parser = initOptParser(commandLineParams())
    while true:
      parser.next()
      case parser.kind
      of cmdEnd: break
      of cmdLongOption, cmdShortOption:
        if parser.key in ["h", "help"]:
          stdout.writeLine("Collect license/NOTICE texts for the resolved native GPUI dependency graph.\n" &
            "usage: collect_sdk_notices --metadata FILE --output FILE")
          return 0
        if parser.kind != cmdLongOption or parser.key notin ["metadata", "output"]:
          raise newException(ValueError, "unknown option: " & parser.key)
        let key = parser.key
        var value = parser.val
        if value.len == 0:
          parser.next()
          if parser.kind != cmdArgument: raise newException(ValueError, "missing value for --" & key)
          value = parser.key
        if key == "metadata": metadataPath = value
        else: outputPath = value
      else: raise newException(ValueError, "unexpected argument: " & parser.key)
    if metadataPath.len == 0 or outputPath.len == 0:
      raise newException(ValueError, "--metadata and --output are required")
    let root = currentSourcePath().parentDir.parentDir
    let notices = collect(parseFile(metadataPath), parseFile(root / "src/leaf/vendor/GPUI-NOTICES.json"))
    createDir(outputPath.parentDir)
    writeFile(outputPath, notices.pretty() & "\n")
    stdout.writeLine("Collected licenses and notices for " & $notices["packages"].len & " native dependencies")
  except CatchableError as error:
    stderr.writeLine("SDK license collection failed: " & error.msg)
    result = 1

when isMainModule: quit(main())
