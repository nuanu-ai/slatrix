import json
import subprocess
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / "check-capabilities.py"


class CheckCapabilitiesTests(unittest.TestCase):
    def check(self, capabilities, files):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "spec").mkdir()
            (root / "spec/capabilities.json").write_text(json.dumps({"capabilities": capabilities}), encoding="utf-8")
            for path, text in files.items():
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text(text, encoding="utf-8")
            return subprocess.run(
                [str(CHECKER), str(root)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30
            )

    def test_done_capabilities_backed_by_tests_pass_and_missing_ones_are_listed(self):
        result = self.check(
            [
                {"id": "message.edit", "what": "Edit your message.", "mac": "done", "android": "missing"},
                {"id": "app.zoom", "what": "Zoom.", "mac": "done", "android": "n/a: Android follows the system font size"},
            ],
            {
                "Tests/SlatrixTests/EditTests.swift": "    // capability: message.edit\n    @Test func edits() {}\n",
                "Tests/SlatrixTests/ZoomTests.swift": "@Test func zooms() {} // capability: app.zoom\n",
            },
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("android is missing 1:\n  message.edit  Edit your message.", result.stdout)
        self.assertNotIn("app.zoom  ", result.stdout)

    def test_done_without_a_test_on_that_platform_fails(self):
        result = self.check(
            [{"id": "message.edit", "what": "Edit your message.", "mac": "done", "android": "done"}],
            {"Tests/SlatrixTests/EditTests.swift": "// capability: message.edit\n"},
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("android: message.edit is done but no test says capability: message.edit", result.stdout)

    def test_every_android_test_folder_counts(self):
        for folder in ("android/app/src/test", "android/app/src/androidTest"):
            with self.subTest(folder=folder):
                result = self.check(
                    [{"id": "auth.sign-in", "what": "Sign in.", "mac": "missing", "android": "done"}],
                    {f"{folder}/kotlin/SignInTest.kt": "    // capability: auth.sign-in\n    @Test fun signsIn() {}\n"},
                )
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_tag_outside_the_ledger_fails(self):
        result = self.check(
            [{"id": "message.edit", "what": "Edit your message.", "mac": "missing", "android": "missing"}],
            {"android/app/src/test/kotlin/EditTest.kt": "// capability: message.edits\n"},
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("EditTest.kt:1 names message.edits, which spec/capabilities.json doesn't list", result.stdout)

    def test_malformed_entries_fail(self):
        for entry in (
            {"id": "app.zoom", "what": "Zoom.", "mac": "missing", "android": "n/a"},
            {"id": "app.zoom", "what": "Zoom.", "mac": "missing", "android": "partly"},
            {"id": "app.zoom", "what": "", "mac": "missing", "android": "missing"},
            {"id": "app.zoom", "what": "Zoom.", "mac": "missing"},
        ):
            with self.subTest(entry=entry):
                self.assertNotEqual(self.check([entry], {}).returncode, 0)
        duplicate = {"id": "app.zoom", "what": "Zoom.", "mac": "missing", "android": "missing"}
        self.assertNotEqual(self.check([duplicate, duplicate], {}).returncode, 0)


if __name__ == "__main__":
    unittest.main()
