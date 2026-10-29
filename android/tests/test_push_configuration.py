import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ANDROID = Path(__file__).resolve().parents[1]
PUSH_GATEWAY = "https://matrixpush-mfdhzgmbba-ew.a.run.app/_matrix/push/v1/notify"


class PushConfigurationTests(unittest.TestCase):
    def configure(self, gateway, google_services, task=":app:help"):
        return subprocess.run(
            [
                str(ANDROID / "gradlew"),
                task,
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

    def test_cloud_run_gateway_configures_with_external_firebase_file(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text("{}", encoding="utf-8")
            result = self.configure(PUSH_GATEWAY, google_services)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_unsafe_gateway_urls_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text("{}", encoding="utf-8")
            for gateway in (
                "https://europe-west1-slatrix-18cdc.cloudfunctions.net/matrixPush/_matrix/push/v1/notify",
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
                    self.assertIn("slatrixPushGateway must be an HTTPS /_matrix/push/v1/notify endpoint.", result.stdout)

    def test_relative_firebase_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text("{}", encoding="utf-8")
            result = self.configure(
                PUSH_GATEWAY, os.path.relpath(google_services, ANDROID)
            )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("slatrixGoogleServices must name an existing absolute file.", result.stdout)

    def test_external_firebase_file_generates_debug_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            google_services = Path(directory) / "google-services.json"
            google_services.write_text(
                json.dumps({
                    "project_info": {
                        "project_number": "123456789012",
                        "project_id": "slatrix-test-fixture",
                    },
                    "client": [{
                        "client_info": {
                            "mobilesdk_app_id": "1:123456789012:android:0123456789abcdef",
                            "android_client_info": {"package_name": "ai.nuanu.slatrix.dev"},
                        },
                        "api_key": [{"current_key": "fictional-test-api-key"}],
                    }],
                    "configuration_version": "1",
                }),
                encoding="utf-8",
            )
            result = self.configure(
                PUSH_GATEWAY, google_services, ":app:processDebugGoogleServices"
            )
        self.assertEqual(result.returncode, 0, result.stdout)
