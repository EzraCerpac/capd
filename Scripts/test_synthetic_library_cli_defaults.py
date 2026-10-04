"""CLI regression coverage for command-specific synthetic database defaults."""

import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

import synthetic_library_migration as migration


class DatabaseDefaultTests(unittest.TestCase):
    def run_cli(self, *arguments):
        with mock.patch.object(sys, "argv", ["synthetic_library_migration.py", *arguments]):
            with contextlib.redirect_stdout(io.StringIO()):
                migration.main()

    def test_backfill_defaults_to_legacy_mac_database(self):
        with mock.patch.object(migration, "backfill_legacy", return_value={"ok": True}) as backfill:
            self.run_cli("backfill", "fixture")

        backfill.assert_called_once_with(Path("fixture"), "capd.sqlite")

    def test_backup_keeps_mobile_captures_database_default(self):
        with mock.patch.object(migration, "backup", return_value={"ok": True}) as backup:
            self.run_cli("backup", "fixture", "--destination", "archive")

        backup.assert_called_once_with(Path("fixture"), Path("archive"), "captures.sqlite")

    def test_explicit_backfill_database_still_overrides_default(self):
        with mock.patch.object(migration, "backfill_legacy", return_value={"ok": True}) as backfill:
            self.run_cli("backfill", "fixture", "--database", "legacy.sqlite")

        backfill.assert_called_once_with(Path("fixture"), "legacy.sqlite")


if __name__ == "__main__":
    unittest.main()
