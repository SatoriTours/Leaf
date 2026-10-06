import std/[base64, httpclient, json, os, strutils, tempfiles, unittest]
import ../../scripts/collect_sdk_notices

proc dependency(directory: string, name = "demo", version = "1.0.0",
                license = "MIT"): JsonNode =
  %*{"id": name & version, "name": name, "version": version,
    "source": "registry", "license": license, "repository": newJNull(),
    "authors": ["Author"], "manifest_path": directory / "Cargo.toml"}

proc metadata(packages: varargs[JsonNode]): JsonNode =
  result = %*{"packages": [{"id": "leaf", "name": "leaf-gpui", "version": "0.1.0",
    "source": newJNull()}], "resolve": {"nodes": [{"id": "leaf", "dependencies": []}]}}
  for package in packages:
    result["packages"].add(package)
    result["resolve"]["nodes"][0]["dependencies"].add(package["id"])
    result["resolve"]["nodes"].add(%*{"id": package["id"], "dependencies": []})

proc unexpected(package: JsonNode): JsonNode =
  raise newException(ValueError, "unneeded download: " & package["name"].getStr())

proc emptyDownload(package: JsonNode): JsonNode = newJObject()

proc notFound(package: JsonNode): JsonNode =
  let error = newException(LicenseHttpError, "HTTP 404")
  error.status = 404
  raise error

suite "SDK license and notice collection":
  test "collects dependency license, notice, nested attribution, and invalid UTF-8":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    writeFile(root / "Cargo.toml", "[package]")
    writeFile(root / "LICENSE", "Actual upstream license and copyright")
    writeFile(root / "NOTICE", "Original attribution\r\nNext line\r")
    createDir(root / "nested")
    writeFile(root / "nested/COPYING.txt", "nested\xe2\x82 attribution\xff")
    writeFile(root / "LICENSE.rs", "source should be excluded")
    writeFile(root / "NOTICE.png", "image should be excluded")
    writeFile(root / "licensee", "unrelated file")
    let collected = collect(metadata(dependency(root)), %*{"packages": []}, unexpected)
    let item = collected["packages"][0]
    check item["texts"]["NOTICE"].getStr() == "Original attribution\nNext line\n"
    check item["texts"]["LICENSE"].getStr() == "Actual upstream license and copyright"
    check item["texts"]["nested/COPYING.txt"].getStr() == "nested\xef\xbf\xbd attribution\xef\xbf\xbd"
    check item["texts"].len == 3
    check item["authors"] == %*["Author"]
    check item["repository"].kind == JNull
    check item["source_archive"].getStr() == "https://static.crates.io/crates/demo/demo-1.0.0.crate"
    check collected["gpui_kit"].getStr() == "0.7.0"

  test "missing material stops release with the package name":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    writeFile(root / "Cargo.toml", "[package]")
    try:
      discard collect(metadata(dependency(root, "missing", "1")), %*{"packages": []}, emptyDownload)
      check false
    except ValueError as error:
      check "license material missing: missing 1" in error.msg

  test "retains exact baseline versions and overwrites with published crate text":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    writeFile(root / "NOTICE", "current")
    let baseline = %*{"packages": [{"name": "demo", "version": "1.0.0",
      "texts": {"NOTICE": "old", "historic/LICENSE": "historic"}}]}
    let item = collect(metadata(dependency(root)), baseline, unexpected)["packages"][0]
    check item["texts"] == %*{"NOTICE": "current", "historic/LICENSE": "historic"}
    let differentVersion = collect(metadata(dependency(root, version = "2")), baseline, unexpected)["packages"][0]
    check differentVersion["texts"] == %*{"NOTICE": "current"}
    check baseline["packages"][0]["texts"]["NOTICE"].getStr() == "old"

  test "traverses cycles and transitive dependencies, excludes unreachable packages, sorts versions":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    writeFile(root / "LICENSE", "local")
    var graph = metadata(dependency(root, "z", "2"), dependency(root, "a", "10"),
      dependency(root, "a", "2"), dependency(root, "unreachable"))
    graph["resolve"]["nodes"][0]["dependencies"] = %*["z2"]
    graph["resolve"]["nodes"][1]["dependencies"] = %*["a2", "a10", "leaf"]
    let items = collect(graph, %*{"packages": []}, unexpected)["packages"]
    check items.len == 3
    check items[0]["name"].getStr() == "a"
    check items[0]["version"].getStr() == "10"
    check items[1]["version"].getStr() == "2"
    check items[2]["name"].getStr() == "z"

  test "offers standard Apache fallback before download and MIT only after 404":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    let baseline = %*{"packages": [{"name": "baseline", "version": "1", "texts": {
      "LICENSE-APACHE": "Apache License Version 2.0", "LICENSE-MIT": " Permission is hereby granted, free of charge"}}]}
    let apache = collect(metadata(dependency(root, license = "MIT OR Apache-2.0")), baseline, unexpected)["packages"][0]
    check apache["selected_license"].getStr() == "Apache-2.0"
    check apache["texts"]["LICENSE-APACHE-2.0"].getStr() == "Apache License Version 2.0"
    let mit = collect(metadata(dependency(root)), baseline, notFound)["packages"][0]
    check mit["selected_license"].getStr() == "MIT"
    check mit["authors"] == %*["Author"]
    check mit["texts"]["LICENSE-MIT"].getStr() == " Permission is hereby granted, free of charge"
    expect ValueError: discard collect(metadata(dependency(root)), baseline, emptyDownload)
    expect ValueError:
      discard collect(metadata(dependency(root, license = "MIT OR BSD-3-Clause")), baseline, notFound)

  test "downloaded material preserves upstream attribution and source":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    let download: DownloadProc = proc(package: JsonNode): JsonNode =
      %*{"texts": {"LICENSE": "Upstream copyright"}, "license_source": "https://example.test/pinned/LICENSE"}
    let item = collect(metadata(dependency(root)), %*{"packages": []}, download)["packages"][0]
    check item["texts"]["LICENSE"].getStr() == "Upstream copyright"
    check item["license_source"].getStr() == "https://example.test/pinned/LICENSE"
    check item["authors"] == %*["Author"]

suite "upstream notice retrieval":
  test "uses cargo pinned revision, normalizes GitHub and retries rewritten history only on 404":
    let root = createTempDir("leaf-notices-", "")
    defer: removeDir(root)
    writeFile(root / ".cargo_vcs_info.json", $ %*{"git": {"sha1": "pinned-sha"}})
    var package = dependency(root)
    package["homepage"] = %"http://github.com/owner/repo.git"
    var calls: seq[(string, string)]
    let fetch: LicenseFetchProc = proc(repository, revision: string): JsonNode =
      calls.add((repository, revision))
      if revision.len > 0:
        let error = newException(LicenseHttpError, "gone")
        error.status = 404
        raise error
      %*{"texts": {"LICENSE": "current license"}, "license_source": "https://example.test/exact-current/LICENSE"}
    check upstream(package, fetch)["license_source"].getStr() == "https://example.test/exact-current/LICENSE"
    check calls == @[("https://github.com/owner/repo.git", "pinned-sha"), ("https://github.com/owner/repo.git", "")]
    let forbidden: LicenseFetchProc = proc(repository, revision: string): JsonNode =
      let error = newException(LicenseHttpError, "forbidden")
      error.status = 403
      raise error
    expect LicenseHttpError: discard upstream(package, forbidden)

  test "GitHub fetch decodes content, keeps source URL, authenticates, and caches by revision":
    clearLicenseCache()
    let oldToken = getEnv("GH_TOKEN")
    let hadToken = existsEnv("GH_TOKEN")
    defer:
      clearLicenseCache()
      if hadToken: putEnv("GH_TOKEN", oldToken)
      else: delEnv("GH_TOKEN")
    putEnv("GH_TOKEN", "test-token")
    var calls = 0
    let get: HttpDownloadProc = proc(url: string, headers: HttpHeaders): string =
      inc calls
      check url == "https://api.github.com/repos/owner/repo/license?ref=pinned"
      check headers["User-Agent"] == "Leaf-SDK-license-collector"
      check headers["Authorization"] == "Bearer test-token"
      $ %*{"name": "LICENSE-MIT", "content": encode("upstream license"),
        "download_url": "https://raw.githubusercontent.com/owner/repo/pinned/LICENSE-MIT"}
    var fetched = fetchLicense("https://github.com/owner/repo.git", "pinned", get)
    check fetched["texts"]["LICENSE-MIT"].getStr() == "upstream license"
    check fetched["license_source"].getStr() == "https://raw.githubusercontent.com/owner/repo/pinned/LICENSE-MIT"
    fetched["texts"]["LICENSE-MIT"] = %"modified locally"
    check fetchLicense("https://github.com/owner/repo.git", "pinned", get)["texts"]["LICENSE-MIT"].getStr() == "upstream license"
    check calls == 1

  test "Redox license defaults to master and other repositories return no material":
    clearLicenseCache()
    defer: clearLicenseCache()
    let get: HttpDownloadProc = proc(url: string, headers: HttpHeaders): string =
      check url == "https://gitlab.redox-os.org/redox/syscall/-/raw/master/LICENSE"
      check not headers.hasKey("Authorization")
      "Redox license"
    let fetched = fetchLicense("https://gitlab.redox-os.org/redox/syscall/", "", get)
    check fetched["texts"]["LICENSE"].getStr() == "Redox license"
    check fetched["license_source"].getStr() == "https://gitlab.redox-os.org/redox/syscall/-/raw/master/LICENSE"
    check fetchLicense("https://example.test/repo", "", get)["texts"].len == 0

  test "upstream decoding rejects malformed UTF-8 and failed fetches are not cached":
    clearLicenseCache()
    defer: clearLicenseCache()
    var calls = 0
    let get: HttpDownloadProc = proc(url: string, headers: HttpHeaders): string =
      inc calls
      $ %*{"name": "LICENSE", "content": encode("invalid\xed\xa0\x80"),
        "download_url": "https://example.test/LICENSE"}
    for attempt in 0..1:
      expect ValueError:
        discard fetchLicense("https://github.com/owner/repo", "bad", get)
    check calls == 2
