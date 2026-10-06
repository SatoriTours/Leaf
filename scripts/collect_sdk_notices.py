#!/usr/bin/env python3
"""Collect license/NOTICE texts for the resolved native GPUI dependency graph."""
import argparse
import base64
import functools
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

@functools.lru_cache(maxsize=None)
def fetch_license(repository, revision):
    headers = {"User-Agent": "Leaf-SDK-license-collector"}
    match = re.match(r"https://github\.com/([^/]+)/([^/#?]+)", repository)
    if match:
        owner, name = match.groups()
        name = name.removesuffix(".git")
        url = f"https://api.github.com/repos/{owner}/{name}/license"
        if revision: url += "?ref=" + revision
        token = os.environ.get("GH_TOKEN")
        if token: headers["Authorization"] = "Bearer " + token
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
            result = json.load(response)
        text = base64.b64decode(result["content"]).decode("utf-8")
        return {result["name"]: text}, result["download_url"]
    if repository.startswith("https://gitlab.redox-os.org/"):
        url = repository.rstrip("/") + "/-/raw/" + (revision or "master") + "/LICENSE"
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
            return {"LICENSE": response.read().decode("utf-8")}, url
    return {}, ""

def upstream(package):
    repository = package.get("repository") or package.get("homepage") or ""
    repository = repository.replace("http://github.com/", "https://github.com/")
    root = Path(package["manifest_path"]).parent
    revision = ""
    vcs = root / ".cargo_vcs_info.json"
    if vcs.is_file(): revision = json.loads(vcs.read_text(encoding="utf-8"))["git"]["sha1"]
    try:
        texts, source = fetch_license(repository, revision)
    except urllib.error.HTTPError as error:
        # Some upstream repositories have rewritten history; record the exact current source.
        if error.code != 404 or not revision: raise
        texts, source = fetch_license(repository, "")
    return {"texts": texts, "license_source": source}

def collect(metadata, baseline, download=upstream):
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node["dependencies"] for node in metadata["resolve"]["nodes"]}
    root = next(package["id"] for package in metadata["packages"] if package["name"] == "leaf-gpui")
    resolved = set()
    pending = [root]
    while pending:
        current = pending.pop()
        if current in resolved: continue
        resolved.add(current)
        pending.extend(nodes.get(current, []))
    old = {(package["name"], package["version"]): package for package in baseline["packages"]}
    apache = next((text for item in baseline["packages"] for name, text in item.get("texts", {}).items()
                   if "apache" in name.lower() and "Version 2.0" in text), "")
    mit = next((text for item in baseline["packages"] for name, text in item.get("texts", {}).items()
                if "mit" in name.lower() and text.lstrip().startswith("Permission is hereby granted")), "")
    notices = []
    for identifier in sorted(resolved, key=lambda value: (packages[value]["name"], packages[value]["version"])):
        package = packages[identifier]
        if not package.get("source"): continue
        item = {key: package.get(key) for key in ("name", "version", "license", "repository", "authors", "source")}
        item["source_archive"] = f"https://static.crates.io/crates/{package['name']}/{package['name']}-{package['version']}.crate"
        item["texts"] = dict(old.get((package["name"], package["version"]), {}).get("texts", {}))
        directory = Path(package["manifest_path"]).parent
        # Also retain notices/licenses nested in crates, beyond the root-only historic inventory.
        for path in sorted(directory.rglob("*")):
            if path.is_file() and re.match(r"^(licen[cs]e|copying|copyright|notice)([-_.]|$)", path.name, re.I) and path.suffix not in (".rs", ".png"):
                item["texts"][path.relative_to(directory).as_posix()] = path.read_text(encoding="utf-8", errors="replace")
        # Apache's standard terms have no package-specific substitutions. Choose this
        # explicitly offered license when older dual-licensed crates omit their copy.
        if not item["texts"] and "Apache-2.0" in (package.get("license") or "") and apache:
            item["texts"] = {"LICENSE-APACHE-2.0": apache}
            item["selected_license"] = "Apache-2.0"
        if not item["texts"]:
            try:
                item.update(download(package))
            except urllib.error.HTTPError as error:
                if error.code == 404 and package.get("license") == "MIT" and mit:
                    # A few old crates (e.g. block 0.1.6) declare MIT but publish no
                    # license file, even upstream. Retain authors/source attribution
                    # and the standard grant; never invent a copyright/year notice.
                    item["texts"] = {"LICENSE-MIT": mit}
                    item["selected_license"] = "MIT"
                else:
                    raise ValueError(f"license retrieval failed for {package['name']} {package['version']}: {error}") from error
            except (OSError, ValueError) as error:
                raise ValueError(f"license retrieval failed for {package['name']} {package['version']}: {error}") from error
        if not item.get("texts"):
            raise ValueError(f"license material missing: {package['name']} {package['version']}")
        notices.append(item)
    return {"gpui_kit": "0.7.0", "packages": notices}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        baseline = json.loads((ROOT / "src/leaf/vendor/GPUI-NOTICES.json").read_text(encoding="utf-8"))
        result = collect(json.loads(args.metadata.read_text(encoding="utf-8")), baseline)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Collected licenses and notices for {len(result['packages'])} native dependencies")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"SDK license collection failed: {error}\n")
