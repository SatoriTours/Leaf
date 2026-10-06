#!/usr/bin/env python3
"""Resolve release channels and publish verified SDK assets with the GitHub CLI."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

TARGETS = ("linux-x86_64", "macos-x86_64", "macos-aarch64", "windows-x86_64")

def release_info(ref, sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("commit must be a full Git SHA")
    if ref == "refs/heads/main":
        return {"channel": "beta", "version": "beta." + sha[:12], "tag": "beta", "commit": sha}
    if re.fullmatch(r"refs/tags/v[0-9]+\.[0-9]+\.[0-9]+", ref):
        tag = ref.removeprefix("refs/tags/")
        return {"channel": "release", "version": tag, "tag": tag, "commit": sha}
    raise ValueError("only main and vX.Y.Z tags can publish an SDK")

def github(*args, payload=None):
    command = ["gh", *map(str, args)]
    if payload is not None: command.extend(["--input", "-"])
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    if args[0] == "api":
        return json.loads(result.stdout) if result.stdout.strip() else None
    return result.stdout

def publish(info, repository, assets, gh=github):
    api = "repos/" + repository
    beta = info["channel"] == "beta"
    if beta and gh("api", api + "/commits/main")["sha"] != info["commit"]:
        print("Skipping stale beta build; main has advanced.")
        return False
    title = "Leaf " + info["version"]
    notes = ("Leaf developer SDK (" + info["channel"] + ").\n\nCommit: `" + info["commit"] +
             "`\n\nIncludes CLI, Leaf sources, Nim 2.2.6 and the native GPUI bridge. "
             "The Windows installer also downloads MinGW. See docs/installation.md for system prerequisites and installation commands.")
    pages = gh("api", "--paginate", "--slurp", api + "/releases?per_page=100")
    releases = [item for page in pages for item in page]
    existing = next((item for item in releases if item["tag_name"] == info["tag"]), None)
    if not beta and existing is not None:
        if not existing.get("draft"):
            raise ValueError("published release already exists; refusing to overwrite " + info["tag"])
        if existing.get("target_commitish") != info["commit"]:
            raise ValueError("existing release draft belongs to a different commit")
    if beta:
        # List requests fail visibly on permission/network errors; an absent beta is normal.
        # Update the rolling beta tag to the exact tested commit, never an untested HEAD.
        refs = gh("api", api + "/git/matching-refs/tags/beta")
        if any(item["ref"] == "refs/tags/beta" for item in refs):
            gh("api", "--method", "PATCH", api + "/git/refs/tags/beta",
               payload={"sha": info["commit"], "force": True})
        else:
            gh("api", "--method", "POST", api + "/git/refs",
               payload={"ref": "refs/tags/beta", "sha": info["commit"]})
    if existing is None:
        existing = gh("api", "--method", "POST", api + "/releases", payload={
            "tag_name": info["tag"], "target_commitish": info["commit"],
            "name": title, "body": notes, "draft": True, "prerelease": beta, "make_latest": "false"})
    # gh release upload has plain-text output rather than JSON.
    command = ["release", "upload", info["tag"], *map(str, assets), "--repo", repository]
    # Replacing assets is safe for a private draft, and permits interrupted uploads to resume.
    command.append("--clobber")
    gh(*command)
    gh("api", "--method", "PATCH", api + "/releases/" + str(existing["id"]), payload={
        "name": title, "body": notes, "draft": False, "prerelease": beta,
        "make_latest": "false" if beta else "legacy"})
    return True

def checked_assets(directory):
    import hashlib
    assets = []
    for target in TARGETS:
        extension = ".zip" if target.startswith("windows") else ".tar.gz"
        archive = directory / ("leaf-sdk-" + target + extension)
        checksum = archive.with_name(archive.name + ".sha256")
        if not archive.is_file() or not checksum.is_file():
            raise ValueError("missing verified SDK artifact: " + str(archive))
        with archive.open("rb") as stream: actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if checksum.read_text().split()[0] != actual:
            raise ValueError("SDK checksum mismatch: " + str(archive))
        assets.extend([archive, checksum])
    return assets

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=os.environ.get("GITHUB_REF", ""))
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--metadata", action="store_true")
    parser.add_argument("--assets", type=Path)
    args = parser.parse_args()
    try:
        info = release_info(args.ref, args.sha)
        if args.metadata:
            print(json.dumps(info))
            output = os.environ.get("GITHUB_OUTPUT")
            if output:
                with open(output, "a", encoding="utf-8") as stream:
                    for key, value in info.items(): stream.write(f"{key}={value}\n")
        else:
            if not args.assets or not args.repository: raise ValueError("--assets and --repository are required")
            publish(info, args.repository, checked_assets(args.assets))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"SDK publication failed: {error}\n")

if __name__ == "__main__": main()
