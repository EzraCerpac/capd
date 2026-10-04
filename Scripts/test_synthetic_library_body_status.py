"""Regression coverage for legacy body quality in offline capture imports."""

import unittest
import uuid

import synthetic_library_migration as migration


class ImportedBodyStatusTests(unittest.TestCase):
    def imported(self, status):
        body = "Saved synthetic body with original spacing.\nSecond paragraph."
        row = {
            "kind": "text",
            "seen_count": 1,
            "created_at": "2026-01-02 03:04:05",
            "body": body,
            "body_status": status,
        }
        payload = {"legacyRow": row, "blob": None, "manualTags": [], "generatedTags": []}
        record = migration.imported_capture(
            "C92F49AC-C890-4F83-838B-B185F04914B0",
            payload,
            uuid.UUID("687238F8-5851-4807-A59B-CE704145E8A9"),
        )
        self.assertEqual(record["generated"]["body"], body)
        self.assertEqual(row["body"], body)
        return record["generated"]

    def test_thin_body_remains_thin(self):
        self.assertIs(self.imported("thin")["bodyIsThin"], True)

    def test_ok_body_remains_non_thin(self):
        self.assertIs(self.imported("ok")["bodyIsThin"], False)

    def test_unspecified_or_unknown_status_does_not_invent_body_quality(self):
        for status in (None, "", "none", "unknown"):
            with self.subTest(status=status):
                self.assertNotIn("bodyIsThin", self.imported(status))


if __name__ == "__main__":
    unittest.main()
