import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ANDROID = Path(__file__).resolve().parents[1]
CLOUD_FUNCTION = (
    "https://europe-west1-slatrix-18cdc.cloudfunctions.net/"
    "matrixPush/_matrix/push/v1/notify"
)


class PushConfigurationTests(unittest.TestCase):
    def configure(self, gateway, google_services):
        return subprocess.run(
            [
                str(ANDROID / "gradlew"),
                ":app:help",
                "--offline",
                "--console=plain",
                f"-PslatrixGoogleServices={google_services}",
                f"-PslatrixPushGateway={gateway}",
            ],
            cwd=ANDROID,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
        )

    def test_cloud_function_gateway_configures_with_external_firebase_file(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text("{}", encoding="utf-8")
            result = self.configure(CLOUD_FUNCTION, google_services)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_unsafe_gateway_urls_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text("{}", encoding="utf-8")
            for gateway in (
                "http://push.example.org/_matrix/push/v1/notify",
                "https://owner@push.example.org/_matrix/push/v1/notify",
                "https://push.example.org/_matrix/push/v1/notify?token=secret",
                "https://push.example.org/_matrix/push/v1/notify#fragment",
                "https:///_matrix/push/v1/notify",
                "https://push.example.org/other",
            ):
                with self.subTest(gateway=gateway):
                    result = self.configure(gateway, google_services)
                    self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_relative_firebase_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text("{}", encoding="utf-8")
            result = self.configure(
                CLOUD_FUNCTION, os.path.relpath(google_services, ANDROID)
            )
        self.assertNotEqual(result.returncode, 0, result.stdout)
