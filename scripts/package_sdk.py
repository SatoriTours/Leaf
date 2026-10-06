#!/usr/bin/env python3
"""Assemble a relocatable developer SDK using only the Python standard library."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    "linux-x86_64": "libleaf_gpui.so",
    "macos-x86_64": "libleaf_gpui.dylib",
    "macos-aarch64": "libleaf_gpui.dylib",
    "windows-x86_64": "leaf_gpui.dll",
}

def package(args):
    windows = args.target.startswith("windows")
    executable = ".exe" if windows else ""
    required = [args.cli, args.bridge, args.nim_root / ("bin/nim" + executable),
                args.nim_root / "lib/system.nim", args.nim_root / "config/nim.cfg"]
    for path in required:
        if not path.is_file():
            raise ValueError(f"SDK input is missing: {path}")
    if args.channel == "release" and not re.fullmatch(r"v\d+\.\d+\.\d+", args.version):
        raise ValueError("release version must be vX.Y.Z")
    if not re.fullmatch(r"[0-9a-f]{6,40}", args.commit):
        raise ValueError("commit must be a Git SHA")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="leaf-sdk-package-") as temporary:
        sdk = Path(temporary) / "leaf-sdk"
        for directory in ("bin", "lib", "toolchain/nim/bin", "licenses"):
            (sdk / directory).mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.cli, sdk / ("bin/leaf" + executable))
        shutil.copy2(args.bridge, sdk / "lib" / TARGETS[args.target])
        shutil.copytree(ROOT / "src", sdk / "src")
        shutil.copy2(ROOT / "LICENSE", sdk / "LICENSE")
        shutil.copy2(args.nim_root / ("bin/nim" + executable), sdk / ("toolchain/nim/bin/nim" + executable))
        for directory in ("lib", "config"):
            shutil.copytree(args.nim_root / directory, sdk / "toolchain/nim" / directory)
        # Keep vendor notices alongside their source files and an SDK inventory.
        vendor = ROOT / "src/leaf/vendor"
        for filename in ("Nim-LICENSE.txt", "GPUI-NOTICES.json", "provenance.json"):
            shutil.copy2(vendor / filename, sdk / "licenses" / filename)
        (sdk / "sdk.json").write_text(json.dumps({
            "schema": 1, "version": args.version, "channel": args.channel,
            "commit": args.commit, "target": args.target, "nim_version": "2.2.6",
        }, indent=2) + "\n", encoding="utf-8")
        (sdk / "licenses/SDK-SOURCES.txt").write_text(
            "Leaf: https://github.com/SatoriTours/Leaf\n"
            "Nim 2.2.6 (MIT): https://nim-lang.org/download/nim-2.2.6.tar.xz\n"
            "GPUI and dependencies: see GPUI-NOTICES.json and src/leaf/vendor\n"
            "Windows installer downloads MinGW directly from https://nim-lang.org/download/mingw64.7z\n"
            "OS graphics libraries, C compiler on Unix and platform runtimes are system prerequisites.\n",
            encoding="utf-8")
        extension = ".zip" if windows else ".tar.gz"
        archive = args.output / ("leaf-sdk-" + args.target + extension)
        if windows:
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
                for path in sorted(sdk.rglob("*")):
                    if path.is_file(): bundle.write(path, path.relative_to(sdk.parent).as_posix())
        else:
            with tarfile.open(archive, "w:gz", dereference=True) as bundle:
                bundle.add(sdk, arcname="leaf-sdk")
        with archive.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        archive.with_name(archive.name + ".sha256").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
        return archive

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("nim-root", "cli", "bridge", "output"):
        parser.add_argument("--" + option, required=True, type=Path)
    parser.add_argument("--target", required=True, choices=TARGETS)
    parser.add_argument("--channel", required=True, choices=("release", "beta"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        print(package(args))
    except (OSError, ValueError) as error:
        parser.exit(1, f"SDK packaging failed: {error}\n")

if __name__ == "__main__": main()
