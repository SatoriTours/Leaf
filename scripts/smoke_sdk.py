#!/usr/bin/env python3
"""Verify a relocated SDK builds a SQLite application without checkout overrides."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def smoke(sdk, headless_only=False):
    cli = sdk / ("bin/leaf.exe" if os.name == "nt" else "bin/leaf")
    env = dict(os.environ)
    for key in ("NIM", "LEAF_LIBRARY", "LEAF_GPUI_ROOT", "LEAF_GPUI_LIBRARY"):
        env.pop(key, None)
    with tempfile.TemporaryDirectory(prefix="leaf sdk smoke ") as directory:
        root = Path(directory)
        project = root / "smoke-app"
        env["LEAF_DATABASE_PATH"] = str(root / "application.sqlite3")
        def run(*args):
            return subprocess.run([str(cli), *map(str, args)], cwd=root, env=env,
                                  text=True, encoding="utf-8", check=True, capture_output=True).stdout
        print(run("--version"), end="")
        metadata = json.loads((sdk / "sdk.json").read_text(encoding="utf-8"))
        assert metadata["channel"] in run("--version")
        report = json.loads(run("doctor", "--json"))
        assert Path(report["nim"]).is_relative_to(sdk), report
        assert Path(report["library"]).is_relative_to(sdk), report
        if os.name == "nt": assert Path(report["cc"]).is_relative_to(sdk), report
        if not headless_only:
            assert report["gpui"]["available"], report["gpui"]
        # Do not require an active display for compilation or headless verification.
        run("g", "scaffold", project)
        run("g", "scaffold", "Note", "title:string", "archived:bool", "--project", project)
        run("--check", project)
        assert (root / "application.sqlite3").is_file()
        run("--check", project)  # replay migrations in a fresh process
        binary = project / ("target/nim/app.exe" if os.name == "nt" else "target/nim/app")
        assert binary.is_file()
        print("SDK relocation + SQLite scaffold build passed")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=lambda value: Path(value).resolve())
    parser.add_argument("--headless-only", action="store_true", help="Local compile check without system graphics libraries")
    args = parser.parse_args()
    smoke(args.sdk, args.headless_only)
