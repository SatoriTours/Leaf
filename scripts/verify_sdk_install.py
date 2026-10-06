#!/usr/bin/env python3
"""CI: run the platform's actual installer, relocated SDK smoke and failed update."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def verify(args):
    with tempfile.TemporaryDirectory(prefix="leaf install ") as directory:
        base = Path(directory)
        mirror = base / "downloads"
        location = mirror / "releases" / ("download/beta" if args.channel == "beta" else "latest/download")
        shutil.copytree(ROOT / "dist/sdk", location)
        prefix = base / "SDK 中文 with spaces"
        bin_dir = base / "commands"
        if os.name == "nt":
            toolchains = mirror / "toolchains"
            toolchains.mkdir()
            for filename in ("mingw64.7z", "mingw64.7z.sha256", "7zr.exe"):
                shutil.copy2(Path(os.environ["RUNNER_TEMP"]) / "leaf-mingw" / filename, toolchains / filename)
            command = ["pwsh", "-NoProfile", "-File", str(ROOT / "install.ps1"), "-Channel", args.channel,
                "-Prefix", str(prefix), "-BinDir", str(bin_dir), "-DownloadBase", mirror.as_uri(), "-NoPath"]
            entry = bin_dir / "leaf.cmd"
        else:
            command = ["sh", str(ROOT / "install.sh"), "--channel", args.channel,
                "--prefix", str(prefix), "--bin-dir", str(bin_dir), "--download-base", mirror.as_uri(), "--no-path"]
            entry = bin_dir / "leaf"
        subprocess.run(command, check=True)
        output = subprocess.check_output([str(entry), "--version"], text=True, encoding="utf-8")
        assert args.version in output and args.channel in output, output
        sdk = next(path for path in (prefix / "versions").iterdir() if not path.name.startswith("."))
        smoke = [os.sys.executable, str(ROOT / "scripts/smoke_sdk.py"), str(sdk)]
        if args.headless_only: smoke.append("--headless-only")
        subprocess.run(smoke, check=True)
        # A second installation should replace the entry without disturbing old builds.
        subprocess.run(command, check=True)
        before = entry.read_bytes() if os.name == "nt" else entry.readlink()
        if os.name == "nt":
            extractor = toolchains / "7zr.exe"
            original = extractor.read_bytes()
            extractor.write_bytes(b"broken extractor")
            assert subprocess.run(command).returncode != 0
            assert before == entry.read_bytes()
            extractor.write_bytes(original)
        extension = ".zip" if os.name == "nt" else ".tar.gz"
        archive = location / ("leaf-sdk-" + args.target + extension)
        archive.write_bytes(b"broken update")
        assert subprocess.run(command).returncode != 0
        assert before == (entry.read_bytes() if os.name == "nt" else entry.readlink())
        assert subprocess.check_output([str(entry), "--version"], text=True, encoding="utf-8") == output
        print("Native installer, channel, relocation, repeat install and failed update verified")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--headless-only", action="store_true")
    verify(parser.parse_args())
