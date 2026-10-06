import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("publish_sdk", ROOT / "scripts/publish_sdk.py")

class PublishTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_release_only_accepts_exact_version_tags(self):
        info = self.module.release_info("refs/tags/v1.2.3", "a" * 40)
        self.assertEqual(info["channel"], "release")
        self.assertEqual(info["version"], "v1.2.3")
        for ref in ("refs/tags/v1.2.3-beta", "refs/tags/v1", "refs/heads/feature", "refs/tags/v1.2.3\n"):
            with self.assertRaises(ValueError): self.module.release_info(ref, "a" * 40)

    def test_main_has_distinct_beta_identity(self):
        info = self.module.release_info("refs/heads/main", "b" * 40)
        self.assertEqual(info, {"channel": "beta", "version": "beta." + "b" * 12,
                                "tag": "beta", "commit": "b" * 40})
        with self.assertRaises(ValueError): self.module.release_info("refs/heads/main", "untrusted-sha")

    def test_stale_beta_does_not_mutate_release(self):
        commands = []
        def gh(*args, payload=None):
            commands.append((args, payload))
            return {"sha": "c" * 40}
        self.assertFalse(self.module.publish(self.module.release_info("refs/heads/main", "b" * 40),
                                            "owner/repo", [], gh))
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][0], ("api", "repos/owner/repo/commits/main"))

    def test_interrupted_release_resumes_same_private_draft(self):
        info = self.module.release_info("refs/tags/v1.2.3", "a" * 40)
        calls = []
        def gh(*args, payload=None):
            calls.append((args, payload))
            if "--slurp" in args:
                return [[{"id": 42, "tag_name": "v1.2.3", "draft": True, "target_commitish": "a" * 40}]]
            if args[0] == "release": return "uploaded"
            return {"id": 42}
        self.assertTrue(self.module.publish(info, "owner/repo", ["sdk.zip"], gh))
        self.assertFalse(any(payload and payload.get("draft") is True for args, payload in calls))
        self.assertIn("--clobber", next(args for args, payload in calls if args[0] == "release"))
        self.assertEqual(calls[-1][1]["make_latest"], "legacy")
        self.assertFalse(calls[-1][1]["draft"])

    def test_published_release_cannot_be_overwritten(self):
        calls = []
        def gh(*args, payload=None):
            calls.append(args)
            return [[{"id": 42, "tag_name": "v1.2.3", "draft": False, "target_commitish": "a" * 40}]]
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            self.module.publish(self.module.release_info("refs/tags/v1.2.3", "a" * 40), "owner/repo", [], gh)
        self.assertEqual(len(calls), 1)

    def test_beta_stays_prerelease_and_never_latest(self):
        calls = []
        def gh(*args, payload=None):
            calls.append((args, payload))
            if args[-1].endswith("/commits/main"): return {"sha": "b" * 40}
            if "--slurp" in args: return [[]]
            if args[-1].endswith("/git/matching-refs/tags/beta"): return []
            return {"id": 42}
        self.module.publish(self.module.release_info("refs/heads/main", "b" * 40), "owner/repo", [], gh)
        self.assertTrue(calls[-1][1]["prerelease"])
        self.assertEqual(calls[-1][1]["make_latest"], "false")
        tag = next(payload for args, payload in calls if payload and payload.get("ref") == "refs/tags/beta")
        self.assertEqual(tag["sha"], "b" * 40)

if __name__ == "__main__": unittest.main()
