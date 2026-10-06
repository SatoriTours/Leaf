"""Real archives and installers; file URLs keep tests independent of networking."""
import hashlib
import json
import os
import platform
import shutil
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SDKTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="leaf sdk test ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        system = "windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else "linux"
        architecture = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
        self.target = system + "-" + architecture
        self.bridge_name = {"windows": "leaf_gpui.dll", "macos": "libleaf_gpui.dylib", "linux": "libleaf_gpui.so"}[system]
        self.extension = ".zip" if os.name == "nt" else ".tar.gz"
        self.nim = self.base / "nim"
        for directory in ("bin", "lib", "config"):
            (self.nim / directory).mkdir(parents=True)
        (self.nim / ("bin/nim.exe" if os.name == "nt" else "bin/nim")).write_text("compiler")
        (self.nim / "lib/system.nim").write_text("discard")
        (self.nim / "config/nim.cfg").write_text("#config")
        self.cli = self.base / ("leaf.exe" if os.name == "nt" else "leaf")
        self.cli.write_text('#!/bin/sh\necho "Leaf v1.2.3 (release, abcdef)"\n')
        self.cli.chmod(0o755)
        self.bridge = self.base / self.bridge_name
        self.bridge.write_bytes(b"bridge")
        self.out = self.base / "downloads/releases/latest/download"

    def package(self, channel="release"):
        if os.name != "nt":
            self.cli.write_text(f'''#!/bin/sh
if [ "$1" = --verify-sdk ]; then
    [ "$2" = {channel} ] && [ "$3" = {self.target} ] && {{ [ -z "$4" ] || [ "$4" = v1.2.3 ]; }}
    exit $?
fi
echo "Leaf v1.2.3 ({channel}, abcdef)"
''')
        command = [sys.executable, str(ROOT / "scripts/package_sdk.py"),
            "--nim-root", str(self.nim), "--cli", str(self.cli), "--bridge", str(self.bridge),
            "--target", self.target, "--version", "v1.2.3", "--channel", channel,
            "--commit", "abcdef", "--output", str(self.out)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.out / ("leaf-sdk-" + self.target + self.extension)

    def install(self, channel="release", shell="sh"):
        env = dict(os.environ, HOME=str(self.base / "home"))
        return subprocess.run([shell, str(ROOT / "install.sh"), "--channel", channel,
            "--prefix", str(self.base / "installed SDK"), "--bin-dir", str(self.base / "bin"),
            "--download-base", (self.base / "downloads").as_uri(), "--no-path"],
            env=env, capture_output=True, text=True)

    @unittest.skipIf(os.name == "nt", "POSIX installer")
    def test_install_under_bash(self):
        shell = os.environ.get("LEAF_TEST_BASH", shutil.which("bash"))
        if not shell: self.skipTest("Bash is unavailable")
        self.package()
        result = self.install(shell=shell)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("v1.2.3", subprocess.check_output([self.base / "bin/leaf", "--version"], text=True))

    @unittest.skipIf(os.name == "nt", "POSIX installer")
    def test_archive_install_and_channel_switch(self):
        archive = self.package()
        with tarfile.open(archive) as bundle:
            names = bundle.getnames()
            for item in ("src/leaf.nim", "src/leaf/templates/scaffold/main.nim", "LICENSE",
                         "toolchain/nim/lib/system.nim", "lib/" + self.bridge_name, "bin/leaf"):
                self.assertIn("leaf-sdk/" + item, names)
            metadata = json.load(bundle.extractfile("leaf-sdk/sdk.json"))
            self.assertEqual(metadata["channel"], "release")
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(),
                         archive.with_name(archive.name + ".sha256").read_text().split()[0])
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = self.base / "bin/leaf"
        first = entry.resolve()
        self.assertIn("v1.2.3", subprocess.check_output([entry], text=True))
        self.out = self.base / "downloads/releases/download/beta"
        self.package("beta")
        result = self.install("beta")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(entry.resolve(), first)
        self.assertEqual(json.loads((entry.resolve().parents[1] / "sdk.json").read_text())["channel"], "beta")

    @unittest.skipIf(os.name == "nt", "POSIX installer")
    def test_bad_checksum_keeps_previous_installation(self):
        archive = self.package()
        self.assertEqual(self.install().returncode, 0)
        old = (self.base / "bin/leaf").resolve()
        archive.write_bytes(b"broken download")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr.lower())
        self.assertEqual((self.base / "bin/leaf").resolve(), old)
        self.assertTrue(old.exists())

    @unittest.skipIf(os.name == "nt", "POSIX installer")
    def test_bad_archive_keeps_previous_installation(self):
        archive = self.package()
        self.assertEqual(self.install().returncode, 0)
        old = (self.base / "bin/leaf").resolve()
        with tarfile.open(archive, "w:gz") as bundle:
            bad = self.base / "malformed"
            bad.write_text("unrelated content")
            bundle.add(bad, arcname="unexpected/file")
        archive.with_name(archive.name + ".sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "\n")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.base / "bin/leaf").resolve(), old)

    @unittest.skipIf(os.name == "nt", "POSIX installer")
    def test_wrong_channel_keeps_previous_installation(self):
        self.package()
        self.assertEqual(self.install().returncode, 0)
        old = (self.base / "bin/leaf").resolve()
        self.package("beta")  # correct hash, incorrect release-channel payload
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("metadata", result.stderr)
        self.assertEqual((self.base / "bin/leaf").resolve(), old)

    @unittest.skipIf(os.name == "nt", "POSIX installer")
    def test_unsupported_platform_fails_before_installing(self):
        tools = self.base / "tools"
        tools.mkdir()
        uname = tools / "uname"
        uname.write_text("#!/bin/sh\necho unsupported\n")
        uname.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["sh", str(ROOT / "install.sh"), "--prefix", str(self.base / "untouched")],
                                capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported", result.stderr)
        self.assertFalse((self.base / "untouched").exists())

    def test_incomplete_toolchain_does_not_publish_archive(self):
        (self.nim / "lib/system.nim").unlink()
        with self.assertRaises(AssertionError):
            self.package()
        self.assertFalse(self.out.exists())

if __name__ == "__main__":
    unittest.main()
