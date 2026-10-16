from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SafariLibraryCaptureTests(unittest.TestCase):
    def test_popup_capture_and_permission_contract(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Safari capture tests require Node.js 20 or newer")
        result = subprocess.run(
            [node, "--test", "iOS/SafariTests/CapturePopupTests.mjs"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
