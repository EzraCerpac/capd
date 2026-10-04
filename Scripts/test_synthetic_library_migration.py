import base64
import contextlib
import json
from pathlib import Path
import sqlite3
import shutil
import tempfile
import unittest
import uuid

import synthetic_library_migration as migration


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="capd-synthetic-migration-")
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / migration.MARKER).write_bytes(migration.MARKER_BYTES)
        (self.source / "assets" / "nested").mkdir(parents=True)
        (self.source / "assets" / "nested" / "image.png").write_bytes(b"synthetic image bytes")
        (self.source / "assets" / "library-owner").write_bytes(b"synthetic ownership marker")
        (self.source / "assets" / "empty").mkdir()
        (self.source / "assets" / "partial.partial").write_bytes(b"incomplete upload")
        self.db = sqlite3.connect(self.source / "captures.sqlite")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA wal_autocheckpoint=0")
        self.db.executescript("""
            CREATE TABLE captures (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT,
                title TEXT, note TEXT, tags TEXT, tags_version INTEGER,
                asset_path TEXT, seen_count INTEGER, last_seen_at TEXT, reminder_at TEXT,
                source_app_bundle_id TEXT, updated_at TEXT, body TEXT, ocr_text TEXT,
                created_at TEXT, extra BLOB);
            CREATE VIRTUAL TABLE captures_fts USING fts5(title, note, tags, content='captures', content_rowid='id');
            CREATE TRIGGER captures_ai AFTER INSERT ON captures BEGIN
                INSERT INTO captures_fts(rowid,title,note,tags) VALUES(new.id,new.title,new.note,new.tags);
            END;
        """)
        self.db.execute("INSERT INTO captures VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (42, "image", "Kestrel", "Reminder note", "manual one", -1,
                         "nested/image.png", 7, "2024-01-02 03:04:05.123", "2028-01-01",
                         "example.synthetic", "2024-03-04", "body", "ocr", "2024-01-01", b"\x00\xff"))
        self.db.execute("INSERT INTO captures VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (81, "text", "Axolotl", "Second", "generated two", 3, None, 1,
                         "2024-01-02", None, None, "2024-01-03", None, None, "2024-01-01", b""))
        self.db.commit()
        self.archive = self.root / "archive"

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def fail_at(self, stage):
        def fail(actual):
            if actual == stage:
                raise RuntimeError("synthetic injected failure")
        return fail

    def test_wal_snapshot_full_assets_fts_rows_and_autoincrement(self):
        self.assertGreater((self.source / "captures.sqlite-wal").stat().st_size, 0)
        source_signature = migration.sql_signature(self.db)
        migration.backup(self.source, self.archive)
        restored = migration.restore(self.archive, self.root / "restored")
        with contextlib.closing(sqlite3.connect(restored / "captures.sqlite")) as db:
            self.assertEqual(source_signature, migration.sql_signature(db))
            self.assertEqual([(42,)], db.execute("SELECT rowid FROM captures_fts WHERE captures_fts MATCH 'kestrel'").fetchall())
            self.assertEqual([(81,)], db.execute("SELECT seq FROM sqlite_sequence WHERE name='captures'").fetchall())
            self.assertEqual(self.db.execute("SELECT * FROM captures").fetchall(), db.execute("SELECT * FROM captures").fetchall())
        self.assertEqual(migration.asset_inventory(self.source, "captures.sqlite"),
                         migration.asset_inventory(restored, "captures.sqlite"))
        self.assertFalse((restored / "captures.sqlite-wal").exists())

    def test_repeat_backup_is_idempotent_and_stale_snapshot_refuses(self):
        first = migration.backup(self.source, self.archive)
        self.assertEqual(first, migration.backup(self.source, self.archive))
        self.db.execute("UPDATE captures SET seen_count=8 WHERE id=42")
        self.db.commit()
        with self.assertRaises(migration.PreparationError):
            migration.backup(self.source, self.archive)
        self.assertEqual(first, migration.verify(self.archive))

    def test_persistent_sqlite_header_pragmas_are_preserved_and_detected(self):
        self.db.execute("PRAGMA user_version=17")
        self.db.execute("PRAGMA application_id=1234")
        migration.backup(self.source, self.archive)
        restored = migration.restore(self.archive, self.root / "restored")
        with contextlib.closing(sqlite3.connect(restored / "captures.sqlite")) as db:
            self.assertEqual((17,), db.execute("PRAGMA user_version").fetchone())
            self.assertEqual((1234,), db.execute("PRAGMA application_id").fetchone())
        self.db.execute("PRAGMA user_version=18")
        with self.assertRaises(migration.PreparationError):
            migration.backup(self.source, self.archive)

    def test_backup_failures_leave_source_intact_and_no_completed_archive(self):
        before = migration.sql_signature(self.db)
        assets = migration.asset_inventory(self.source, "captures.sqlite")
        for stage in ("database", "assets", "publish"):
            with self.subTest(stage=stage), self.assertRaises(RuntimeError):
                migration.backup(self.source, self.archive, failure=self.fail_at(stage))
            self.assertFalse(self.archive.exists())
            self.assertEqual(before, migration.sql_signature(self.db))
            self.assertEqual(assets, migration.asset_inventory(self.source, "captures.sqlite"))

    def test_restore_failure_corruption_and_overwrite_refuse(self):
        migration.backup(self.source, self.archive)
        target = self.root / "restored"
        for stage in ("restore-copy", "restore-verify"):
            with self.assertRaises(RuntimeError):
                migration.restore(self.archive, target, self.fail_at(stage))
            self.assertFalse(target.exists())
        migration.restore(self.archive, target)
        with self.assertRaises(FileExistsError):
            migration.restore(self.archive, target)
        (self.archive / "payload" / "assets" / "nested" / "image.png").write_bytes(b"corrupt")
        with self.assertRaises(migration.PreparationError):
            migration.restore(self.archive, self.root / "bad-restore")
        self.assertFalse((self.root / "bad-restore").exists())

    def test_asset_mutation_during_backup_fails(self):
        def mutate(stage):
            if stage == "database":
                (self.source / "assets" / "nested" / "image.png").write_bytes(b"changed")
        with self.assertRaises(migration.PreparationError):
            migration.backup(self.source, self.archive, failure=mutate)
        self.assertFalse(self.archive.exists())

    def test_backfill_preserves_rows_fts_metadata_tags_blobs_and_ids(self):
        original = self.db.execute("SELECT * FROM captures").fetchall()
        first = migration.backfill_legacy(self.source, "captures.sqlite")
        self.assertEqual({42, 81}, set(first))
        self.assertEqual(2, len(set(first.values())))
        self.assertEqual(first, migration.backfill_legacy(self.source, "captures.sqlite"))
        self.assertEqual(original, self.db.execute("SELECT * FROM captures").fetchall())
        rows = self.db.execute("SELECT local_id,global_id,payload FROM sync_legacy_snapshot ORDER BY local_id").fetchall()
        self.assertEqual(2, len(rows))
        image, text = [json.loads(row[2]) for row in rows]
        self.assertEqual(7, image["legacyRow"]["seen_count"])
        self.assertEqual({"blob": "AP8="}, image["legacyRow"]["extra"])
        self.assertEqual(["manual", "one"], image["manualTags"])
        self.assertEqual([], image["generatedTags"])
        self.assertEqual(["generated", "two"], text["generatedTags"])
        self.assertEqual("nested/image.png", image["blob"]["path"])
        self.assertEqual([(42,)], self.db.execute("SELECT rowid FROM captures_fts WHERE captures_fts MATCH 'kestrel'").fetchall())
        migration.backup(self.source, self.archive)
        copy = migration.restore(self.archive, self.root / "restored")
        self.assertEqual(first, migration.backfill_legacy(copy, "captures.sqlite"))

    def test_backfill_rollback_missing_image_and_changed_row(self):
        with self.assertRaises(RuntimeError):
            migration.backfill_legacy(self.source, "captures.sqlite", self.fail_at("backfill-row"))
        self.assertEqual([], self.db.execute("SELECT name FROM sqlite_master WHERE name='sync_capture_ids'").fetchall())
        asset = self.source / "assets" / "nested" / "image.png"
        asset.unlink()
        with self.assertRaises(migration.PreparationError):
            migration.backfill_legacy(self.source, "captures.sqlite")
        asset.write_bytes(b"synthetic image bytes")
        first = migration.backfill_legacy(self.source, "captures.sqlite")
        self.db.execute("UPDATE captures SET note='modified' WHERE id=42")
        self.db.commit()
        with self.assertRaises(migration.PreparationError):
            migration.backfill_legacy(self.source, "captures.sqlite")
        self.assertEqual(first, dict(self.db.execute("SELECT * FROM sync_capture_ids")))

    def test_existing_uuid_preserved_and_unsafe_asset_refuses(self):
        identity = str(uuid.uuid4())
        self.db.execute("CREATE TABLE sync_capture_ids (local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE)")
        self.db.execute("INSERT INTO sync_capture_ids VALUES (42,?)", (identity,))
        self.db.commit()
        self.assertEqual(identity, migration.backfill_legacy(self.source, "captures.sqlite")[42])
        self.db.execute("UPDATE captures SET asset_path='../outside' WHERE id=42")
        self.db.commit()
        with self.assertRaises(migration.PreparationError):
            migration.backfill_legacy(self.source, "captures.sqlite")

    def test_marker_symlink_and_overlapping_trees_refuse(self):
        with self.assertRaises(migration.PreparationError):
            migration.backup(self.source, self.source / "archive")
        (self.source / "assets" / "link").symlink_to("nested/image.png")
        with self.assertRaises(migration.PreparationError):
            migration.backup(self.source, self.archive)
        (self.source / "assets" / "link").unlink()
        (self.source / migration.MARKER).unlink()
        with self.assertRaises(migration.PreparationError):
            migration.backup(self.source, self.archive)

    def test_populated_client_plan_preserves_exact_bytes_and_blocks_sequence_seed(self):
        device, operation, capture = [str(uuid.uuid4()).upper() for _ in range(3)]
        payload = json.dumps({"id": operation, "deviceID": device, "sequence": 9,
                              "captureID": capture, "baseRevision": 7,
                              "mutation": {"edit": {"_0": {"note": {"value": "exact pending"}}}}}, indent=3).encode()
        self.db.executescript("""
            CREATE TABLE sync_meta (id INTEGER PRIMARY KEY, role TEXT, device TEXT,
                sequence INTEGER, cursor INTEGER, floor INTEGER, observed_sequence INTEGER);
            CREATE TABLE sync_binding (id INTEGER PRIMARY KEY, payload BLOB);
            CREATE TABLE sync_outbox (sequence INTEGER PRIMARY KEY, id TEXT, payload BLOB);
            CREATE TABLE sync_records (id TEXT PRIMARY KEY,payload BLOB);
            CREATE TABLE sync_aliases (id TEXT PRIMARY KEY,canonical TEXT);
            CREATE TABLE sync_rejections (id TEXT PRIMARY KEY,payload BLOB);
            CREATE TABLE mobile_captures (localID INTEGER PRIMARY KEY,id TEXT,manualTags TEXT,generatedTags TEXT);
        """)
        self.db.execute("INSERT INTO sync_meta VALUES (1,'client',?,9,7,2,6)", (device,))
        self.db.execute("INSERT INTO sync_outbox VALUES (9,?,?)", (operation, payload))
        self.db.execute("INSERT INTO sync_records VALUES (?,?)", (capture, b"accepted snapshot bytes"))
        self.db.execute("INSERT INTO sync_rejections VALUES ('rejected',?)", (b"exact rejected bytes",))
        self.db.execute("INSERT INTO mobile_captures VALUES (42,?,'[\"manual\"]','[\"generated\"]')", (capture,))
        self.db.commit()
        before = migration.sql_signature(self.db)
        binding = {"libraryID": str(uuid.uuid4()), "serviceID": str(uuid.uuid4())}
        prepared = migration.prepare_enrollment(self.source, self.archive, binding)
        plan = prepared["enrollment"]
        self.assertEqual("blocked", plan["activation"])
        self.assertFalse(plan["completeSequenceReplayCandidate"])
        self.assertEqual(device, plan["deviceState"]["device"])
        self.assertEqual(9, plan["deviceState"]["sequence"])
        self.assertEqual(payload, base64.b64decode(plan["pending"][0]["payloadBase64"]))
        self.assertEqual(before, migration.sql_signature(self.db))
        self.assertEqual(prepared, migration.prepare_enrollment(self.source, self.archive, binding))
        restored = migration.restore(self.archive, self.root / "restored")
        self.assertEqual(plan, migration.enrollment_plan(restored, binding))
        self.db.execute("UPDATE sync_outbox SET sequence=8")
        self.db.commit()
        with self.assertRaises(migration.PreparationError):
            migration.enrollment_plan(self.source, binding)

    def authority(self):
        root = self.root / "authority"
        root.mkdir()
        (root / migration.MARKER).write_bytes(migration.MARKER_BYTES)
        (root / "assets").mkdir()
        binding = {key: str(uuid.uuid4()).upper() for key in ("libraryID", "serviceID")}
        (root / "assets" / "library-owner").write_bytes(migration.encode(binding))
        with contextlib.closing(sqlite3.connect(root / "server.sqlite")) as db:
            db.executescript("""
                CREATE TABLE sync_meta (id INTEGER PRIMARY KEY,role TEXT,device TEXT,sequence INTEGER,cursor INTEGER,floor INTEGER,observed_sequence INTEGER);
                INSERT INTO sync_meta VALUES (1,'server',NULL,0,0,0,0);
                CREATE TABLE sync_binding (id INTEGER PRIMARY KEY,payload BLOB);
                CREATE TABLE sync_records (id TEXT PRIMARY KEY,payload BLOB);
                CREATE TABLE sync_aliases (id TEXT PRIMARY KEY,canonical TEXT);
                CREATE TABLE sync_receipts (id TEXT PRIMARY KEY,operation BLOB,receipt BLOB);
                CREATE TABLE sync_devices (id TEXT PRIMARY KEY,sequence INTEGER);
                CREATE TABLE sync_feed (cursor INTEGER PRIMARY KEY AUTOINCREMENT,payload BLOB);
                CREATE TABLE sync_outbox (sequence INTEGER PRIMARY KEY,id TEXT,payload BLOB);
                CREATE TABLE sync_visible (local_id INTEGER PRIMARY KEY,id TEXT,payload BLOB);
                CREATE TABLE sync_rejections (id TEXT PRIMARY KEY,payload BLOB);
                CREATE TABLE sync_observed (id TEXT PRIMARY KEY);
            """)
            db.execute("INSERT INTO sync_binding VALUES (1,?)", (migration.encode(binding),))
            db.commit()
        return root, binding

    def test_initial_mac_import_checkpoint_metadata_blobs_and_replay(self):
        ids = migration.backfill_legacy(self.source, "captures.sqlite")
        migration.backup(self.source, self.archive)
        authority, binding = self.authority()
        import_id = str(uuid.uuid4())
        result = migration.import_initial_mac(self.archive, authority, binding, import_id)
        self.assertEqual(2, result["count"])
        self.assertFalse(result["replayed"])
        with contextlib.closing(sqlite3.connect(authority / "server.sqlite")) as db:
            baseline = migration.sql_signature(db)
            rows = dict(db.execute("SELECT id,payload FROM sync_records"))
            self.assertEqual(set(ids.values()), set(rows))
            image = json.loads(rows[ids[42]])
            self.assertEqual(7, image["seenCount"])
            self.assertEqual("example.synthetic", image["metadata"]["sourceAppBundleID"])
            self.assertEqual(migration.shared_date("2024-03-04"), image["metadata"]["updatedAt"])
            self.assertEqual(migration.shared_date("2024-01-02 03:04:05.123"), image["metadata"]["lastSeenAt"])
            self.assertEqual(migration.shared_date("2028-01-01"), image["metadata"]["reminderAt"])
            self.assertEqual(["manual", "one"], image["manualTags"])
            self.assertEqual(["generated", "two"], json.loads(rows[ids[81]])["generated"]["tags"])
            self.assertEqual((1, 1), db.execute("SELECT cursor,floor FROM sync_meta").fetchone())
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM sync_devices").fetchone()[0])
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM sync_receipts").fetchone()[0])
            sidecar = json.loads(db.execute("SELECT payload FROM sync_imported_legacy WHERE local_id=42").fetchone()[0])
            self.assertEqual("2028-01-01", sidecar["legacyRow"]["reminder_at"])
            blob = image["source"]["blob"]
            self.assertEqual(b"synthetic image bytes", (authority / "assets" / blob["digest"]).read_bytes())
        self.assertTrue(migration.import_initial_mac(self.archive, authority, binding, import_id)["replayed"])
        with contextlib.closing(sqlite3.connect(authority / "server.sqlite")) as db:
            self.assertEqual(baseline, migration.sql_signature(db))
        with self.assertRaises(migration.PreparationError):
            migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()))

    def test_initial_import_failure_rollback_and_bound_authority_checks(self):
        migration.backfill_legacy(self.source, "captures.sqlite")
        migration.backup(self.source, self.archive)
        authority, binding = self.authority()
        before = migration.inventory(authority / "assets")
        with contextlib.closing(sqlite3.connect(authority / "server.sqlite")) as db:
            original = migration.sql_signature(db)
        for stage in ("import-asset", "import-row", "import-commit"):
            with self.assertRaises(RuntimeError):
                migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()), failure=self.fail_at(stage))
            with contextlib.closing(sqlite3.connect(authority / "server.sqlite")) as db:
                self.assertEqual(original, migration.sql_signature(db))
            self.assertEqual(before, migration.inventory(authority / "assets"))
        wrong = dict(binding, libraryID=str(uuid.uuid4()).upper())
        with self.assertRaises(migration.PreparationError):
            migration.import_initial_mac(self.archive, authority, wrong, str(uuid.uuid4()))
        with contextlib.closing(sqlite3.connect(authority / "server.sqlite")) as db:
            db.execute("UPDATE sync_meta SET cursor=3")
            db.commit()
        with self.assertRaises(migration.PreparationError):
            migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()))

    def test_standalone_host_layout_and_unsafe_blob_directory(self):
        migration.backfill_legacy(self.source, "captures.sqlite")
        migration.backup(self.source, self.archive)
        authority, binding = self.authority()
        (authority / "assets").rename(authority / "blobs")
        (authority / "server.sqlite").rename(authority / "authority.sqlite")
        before = migration.inventory(authority)
        for name in ("../blobs", str(authority / "blobs"), ".", ""):
            with self.assertRaises(migration.PreparationError):
                migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()),
                                             authority_database="authority.sqlite", authority_assets=name)
            self.assertEqual(before, migration.inventory(authority))
        result = migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()),
                                              authority_database="authority.sqlite", authority_assets="blobs")
        self.assertEqual(2, result["count"])
        self.assertFalse((authority / "assets").exists())
        with contextlib.closing(sqlite3.connect(authority / "authority.sqlite")) as db:
            records = [json.loads(row[0]) for row in db.execute("SELECT payload FROM sync_records")]
        image = next(record for record in records if record["source"]["kind"] == "image")
        self.assertEqual(b"synthetic image bytes", (authority / "blobs" / image["source"]["blob"]["digest"]).read_bytes())

    def test_import_rejects_source_drift_and_self_consistent_unsafe_sidecar(self):
        migration.backfill_legacy(self.source, "captures.sqlite")
        self.db.execute("UPDATE captures SET title='New title' WHERE id=42")
        self.db.commit()
        migration.backup(self.source, self.archive)
        authority, binding = self.authority()
        with self.assertRaises(migration.PreparationError):
            migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()))
        shutil.rmtree(self.archive)
        self.db.execute("UPDATE captures SET asset_path='../outside' WHERE id=42")
        raw = self.db.execute("SELECT payload FROM sync_legacy_snapshot WHERE local_id=42").fetchone()[0]
        payload = json.loads(raw)
        payload["legacyRow"]["title"] = "New title"
        payload["legacyRow"]["asset_path"] = "../outside"
        payload["blob"]["path"] = "../outside"
        self.db.execute("UPDATE sync_legacy_snapshot SET payload=? WHERE local_id=42", (migration.encode(payload),))
        self.db.commit()
        migration.backup(self.source, self.archive)
        with self.assertRaises(migration.PreparationError):
            migration.import_initial_mac(self.archive, authority, binding, str(uuid.uuid4()))


if __name__ == "__main__":
    unittest.main()
