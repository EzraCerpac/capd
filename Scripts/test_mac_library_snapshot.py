import contextlib
import json
from pathlib import Path
import sqlite3
import unittest
import uuid

import mac_library_snapshot as snapshot
import synthetic_library_migration as migration
import test_synthetic_library_migration as fixtures


class RealSourceAdapterTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.MigrationTests()
        self.fixture.setUp()
        self.source = self.fixture.source
        (self.source / migration.MARKER).unlink()
        self.fixture.db.close()
        (self.source / "captures.sqlite").rename(self.source / snapshot.DATABASE)
        self.fixture.db = sqlite3.connect(self.source / snapshot.DATABASE)
        self.fixture.db.execute("PRAGMA journal_mode=WAL")
        self.fixture.db.execute("PRAGMA wal_autocheckpoint=0")
        self.fixture.db.execute("UPDATE captures SET seen_count=seen_count+1 WHERE id=42")
        self.fixture.db.commit()
        self.archive = self.fixture.archive
        self.work = self.source.parent / "real-copy"

    def tearDown(self):
        self.fixture.tearDown()

    def test_readonly_wal_snapshot_restore_and_exact_source_preservation(self):
        signature = migration.sql_signature(self.fixture.db)
        before = migration.inventory(self.source)
        manifest = snapshot.capture_quiesced(self.source, self.archive)
        self.assertIn("capd.sqlite-wal", before)
        self.assertEqual(migration.inventory(self.source), before)
        self.assertEqual(manifest["format"], snapshot.RAW_FORMAT)
        snapshot.restore_copy(self.archive, self.work)
        with contextlib.closing(migration.connect(self.work / snapshot.DATABASE, readonly=True)) as db:
            self.assertEqual(signature, migration.sql_signature(db))
        self.assertEqual(migration.inventory(self.source), before)
        self.assertFalse((self.source / snapshot.COPY_MARKER).exists())
        self.assertFalse((self.work / migration.MARKER).exists())
        self.assertEqual(snapshot.verify_raw(self.archive), manifest)

    def test_race_refuses_and_removes_only_partial_destination(self):
        def race(stage):
            if stage == "copy":
                (self.source / "assets" / "changed").write_bytes(b"synthetic race")
        with self.assertRaises(migration.PreparationError):
            snapshot.capture_quiesced(self.source, self.archive, failure=race)
        self.assertFalse(self.archive.exists())
        self.assertTrue((self.source / "assets" / "changed").exists())

    def test_symlinks_overlap_and_existing_destinations_refused(self):
        before = migration.inventory(self.source)
        with self.assertRaises(migration.PreparationError):
            snapshot.capture_quiesced(self.source, self.source / "nested")
        self.archive.mkdir()
        with self.assertRaises(migration.PreparationError):
            snapshot.capture_quiesced(self.source, self.archive)
        self.assertEqual(migration.inventory(self.source), before)
        self.archive.rmdir()
        (self.source / "assets" / "link").symlink_to(self.source / snapshot.DATABASE)
        with self.assertRaises(migration.PreparationError):
            snapshot.capture_quiesced(self.source, self.archive)
        self.assertFalse(self.archive.exists())

    def test_typed_copy_backfill_import_and_repeat_preserve_original(self):
        before = migration.inventory(self.source)
        manifest = snapshot.capture_quiesced(self.source, self.archive)
        snapshot.restore_copy(self.archive, self.work)
        identities = snapshot.backfill(self.work)
        self.assertEqual(len(identities), 2)
        prepared = self.source.parent / "prepared-real-archive"
        snapshot.archive_prepared(self.work, prepared)
        authority, binding = self.fixture.authority()
        (authority / migration.MARKER).unlink()
        (authority / "server.sqlite").rename(authority / "authority.sqlite")
        (authority / "assets").rename(authority / "blobs")
        owner = {"format": snapshot.PREPARED_FORMAT, "snapshotID": manifest["snapshotID"],
                 "authorityRoot": str(authority), "binding": binding}
        (authority / snapshot.COPY_MARKER).write_bytes(migration.encode(owner))
        import_id = str(uuid.uuid4())
        first = snapshot.import_copy(prepared, authority, binding, import_id)
        second = snapshot.import_copy(prepared, authority, binding, import_id)
        self.assertEqual(first["count"], 2)
        self.assertTrue(second["replayed"])
        self.assertEqual(migration.inventory(self.source), before)
        with contextlib.closing(sqlite3.connect(authority / "authority.sqlite")) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sync_records").fetchone()[0], 2)
        with self.assertRaises(migration.PreparationError):
            migration.verify(prepared)

    def test_corruption_and_wrong_working_copy_origin_refused(self):
        snapshot.capture_quiesced(self.source, self.archive)
        snapshot.restore_copy(self.archive, self.work)
        descriptor = json.loads((self.work / snapshot.COPY_MARKER).read_bytes())
        descriptor["copyRoot"] = str(self.source)
        (self.work / snapshot.COPY_MARKER).write_bytes(migration.encode(descriptor))
        with self.assertRaises(migration.PreparationError):
            snapshot.backfill(self.work)
        (self.archive / "payload" / snapshot.DATABASE).write_bytes(b"corrupt synthetic snapshot")
        with self.assertRaises(migration.PreparationError):
            snapshot.verify_raw(self.archive)


if __name__ == "__main__":
    unittest.main()
