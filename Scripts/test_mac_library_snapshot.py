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

    def copy_source(self):
        snapshot.capture_quiesced(self.source, self.archive)
        snapshot.restore_copy(self.archive, self.work)

    def assert_backfill_refused_without_changes(self):
        before = migration.inventory(self.work)
        source_before = migration.inventory(self.source)
        with self.assertRaisesRegex(migration.PreparationError, "unbound and unused"):
            snapshot.backfill(self.work)
        self.assertEqual(migration.inventory(self.work), before)
        self.assertEqual(migration.inventory(self.source), source_before)
        with contextlib.closing(migration.connect(self.work / snapshot.DATABASE, readonly=True)) as db:
            self.assertIsNone(db.execute("SELECT name FROM sqlite_master WHERE name='sync_capture_ids'").fetchone())

    def test_bound_source_rejected_before_backfill(self):
        self.fixture.db.execute("CREATE TABLE sync_binding(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
        self.fixture.db.execute("INSERT INTO sync_binding VALUES(1, ?)", (migration.encode({"libraryID": str(uuid.uuid4())}),))
        self.fixture.db.commit()
        self.copy_source()
        self.assert_backfill_refused_without_changes()

    def test_used_device_and_outbox_source_rejected_before_backfill(self):
        self.fixture.db.execute("CREATE TABLE sync_meta(id INTEGER PRIMARY KEY, role TEXT, device TEXT, sequence INTEGER, cursor INTEGER, floor INTEGER, observed_sequence INTEGER)")
        self.fixture.db.execute("INSERT INTO sync_meta VALUES(1, 'client', ?, 2, 0, 0, 0)", (str(uuid.uuid4()),))
        self.fixture.db.execute("CREATE TABLE sync_outbox(sequence INTEGER PRIMARY KEY, id TEXT, payload BLOB)")
        self.fixture.db.execute("INSERT INTO sync_outbox VALUES(2, ?, ?)", (str(uuid.uuid4()), b'{}'))
        self.fixture.db.commit()
        self.copy_source()
        self.assert_backfill_refused_without_changes()

    def test_sync_history_and_unknown_state_rejected_without_changes(self):
        self.copy_source()
        for table in ("sync_devices", "sync_records", "sync_aliases", "sync_receipts", "sync_feed",
                      "sync_visible", "sync_rejections", "sync_observed", "sync_note_conflicts",
                      "sync_initial_import", "sync_content_snapshot_imports", "sync_future_history"):
            with self.subTest(table=table):
                with contextlib.closing(migration.connect(self.work / snapshot.DATABASE)) as db:
                    db.execute(f'CREATE TABLE "{table}"(payload BLOB)')
                    db.execute(f'INSERT INTO "{table}" VALUES(?)', (b'{}',))
                    db.commit()
                self.assert_backfill_refused_without_changes()
                with contextlib.closing(migration.connect(self.work / snapshot.DATABASE)) as db:
                    db.execute(f'DROP TABLE "{table}"')
                    db.commit()

    def test_used_or_malformed_metadata_rejected_without_changes(self):
        self.copy_source()
        with contextlib.closing(migration.connect(self.work / snapshot.DATABASE)) as db:
            db.execute("CREATE TABLE sync_meta(id INTEGER, role TEXT, device TEXT, sequence INTEGER, cursor INTEGER, floor INTEGER, observed_sequence INTEGER)")
            db.commit()
        device = str(uuid.uuid4())
        rows = [(1, "client", device, 0, 0, 0, 0)]
        for index in range(3, 7):
            row = list(rows[0])
            row[index] = 1
            rows.append(tuple(row))
        rows = rows[1:] + [(1, "server", None, 0, 0, 0, 0),
                          (1, "client", "invalid", 0, 0, 0, 0),
                          (1, "client", device, None, 0, 0, 0),
                          (2, "client", device, 0, 0, 0, 0)]
        for row in rows:
            with self.subTest(row=row):
                with contextlib.closing(migration.connect(self.work / snapshot.DATABASE)) as db:
                    db.execute("INSERT INTO sync_meta VALUES(?, ?, ?, ?, ?, ?, ?)", row)
                    db.commit()
                self.assert_backfill_refused_without_changes()
                with contextlib.closing(migration.connect(self.work / snapshot.DATABASE)) as db:
                    db.execute("DELETE FROM sync_meta")
                    db.commit()

    def test_unused_schema_and_preparatory_state_remain_idempotent(self):
        self.fixture.db.execute("CREATE TABLE sync_meta(id INTEGER PRIMARY KEY, role TEXT, device TEXT, sequence INTEGER, cursor INTEGER, floor INTEGER, observed_sequence INTEGER)")
        self.fixture.db.execute("INSERT INTO sync_meta VALUES(1, 'client', ?, 0, 0, 0, 0)", (str(uuid.uuid4()),))
        for table in ("sync_binding", "sync_outbox", "sync_devices", "sync_future_history"):
            self.fixture.db.execute(f'CREATE TABLE "{table}"(payload BLOB)')
        self.fixture.db.commit()
        self.copy_source()
        first = snapshot.backfill(self.work)
        before = migration.inventory(self.work)
        self.assertEqual(snapshot.backfill(self.work), first)
        self.assertEqual(migration.inventory(self.work), before)
        prepared = self.source.parent / "unused-prepared"
        snapshot.archive_prepared(self.work, prepared)
        self.assertEqual(snapshot.verify_prepared(prepared)["format"], snapshot.PREPARED_FORMAT)

    def test_cleared_history_still_rejected_by_high_water_mark(self):
        self.fixture.db.execute("CREATE TABLE sync_feed(cursor INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB)")
        self.fixture.db.execute("INSERT INTO sync_feed(payload) VALUES(?)", (b'{}',))
        self.fixture.db.execute("DELETE FROM sync_feed")
        self.fixture.db.commit()
        self.copy_source()
        self.assert_backfill_refused_without_changes()

    def test_binding_after_backfill_cannot_be_archived(self):
        self.copy_source()
        snapshot.backfill(self.work)
        with contextlib.closing(migration.connect(self.work / snapshot.DATABASE)) as db:
            db.execute("CREATE TABLE sync_binding(id INTEGER PRIMARY KEY, payload BLOB)")
            db.execute("INSERT INTO sync_binding VALUES(1, ?)", (b'{}',))
            db.commit()
        before = migration.inventory(self.work)
        prepared = self.source.parent / "bound-prepared"
        with self.assertRaisesRegex(migration.PreparationError, "unbound and unused"):
            snapshot.archive_prepared(self.work, prepared)
        self.assertFalse(prepared.exists())
        self.assertEqual(migration.inventory(self.work), before)

    def test_self_consistent_prepared_archive_cannot_bypass_source_guard(self):
        self.copy_source()
        snapshot.backfill(self.work)
        prepared = self.source.parent / "used-prepared"
        snapshot.archive_prepared(self.work, prepared)
        with contextlib.closing(migration.connect(prepared / "payload" / snapshot.DATABASE)) as db:
            db.execute("CREATE TABLE sync_aliases(id TEXT PRIMARY KEY, canonical TEXT)")
            db.execute("INSERT INTO sync_aliases VALUES(?, ?)", (str(uuid.uuid4()), str(uuid.uuid4())))
            db.commit()
            signature = migration.sql_signature(db)
        manifest_path = prepared / "manifest.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["sourceSQL"] = signature
        manifest["files"] = migration.inventory(prepared / "payload")
        manifest_path.write_bytes(migration.encode(manifest))
        before = migration.inventory(prepared)
        with self.assertRaisesRegex(migration.PreparationError, "unbound and unused"):
            snapshot.verify_prepared(prepared)
        with self.assertRaisesRegex(migration.PreparationError, "unbound and unused"):
            snapshot.import_copy(prepared, self.source.parent / "not-created-authority", {}, str(uuid.uuid4()))
        self.assertEqual(migration.inventory(prepared), before)


if __name__ == "__main__":
    unittest.main()
