import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class NoticesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("collect_sdk_notices", ROOT / "scripts/collect_sdk_notices.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_collects_actual_dependency_license_and_notice(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Cargo.toml").write_text("[package]")
            (root / "LICENSE").write_text("Actual upstream license and copyright")
            (root / "NOTICE").write_text("Original attribution")
            packages = [{"id": "leaf", "name": "leaf-gpui", "version": "0.1.0", "source": None},
                        {"id": "dep", "name": "demo", "version": "1.0.0", "source": "registry",
                         "license": "MIT", "repository": None, "authors": ["Author"], "manifest_path": str(root / "Cargo.toml")}]
            metadata = {"packages": packages, "resolve": {"nodes": [
                {"id": "leaf", "dependencies": ["dep"]}, {"id": "dep", "dependencies": []}]}}
            result = self.module.collect(metadata, {"packages": []}, lambda package: self.fail("unneeded download"))
            self.assertEqual(result["packages"][0]["texts"]["NOTICE"], "Original attribution")
            self.assertIn("LICENSE", result["packages"][0]["texts"])

    def test_missing_material_stops_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "Cargo.toml"
            manifest.write_text("[package]")
            metadata = {"packages": [
                {"id": "leaf", "name": "leaf-gpui", "version": "1", "source": None},
                {"id": "dep", "name": "missing", "version": "1", "source": "registry", "license": "MIT",
                 "manifest_path": str(manifest)}], "resolve": {"nodes": [
                    {"id": "leaf", "dependencies": ["dep"]}, {"id": "dep", "dependencies": []}]}}
            with self.assertRaisesRegex(ValueError, "missing"):
                self.module.collect(metadata, {"packages": []}, lambda package: {})

if __name__ == "__main__": unittest.main()
