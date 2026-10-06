import contextlib
import hashlib
import json
import sqlite3
import struct
import unittest
from unittest import mock
import uuid
import zlib

import mac_library_snapshot as snapshot
import synthetic_library_migration as migration
import test_mac_library_snapshot as fixtures


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"\0" + bytes([90, 130, 170, 255]) * 64
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels * 64)) + chunk(b"IEND", b""))


class WebsiteIconLibraryExportTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.RealSourceAdapterTests()
        self.fixture.setUp()
        self.source = self.fixture.source
        self.db = self.fixture.fixture.db
        self.db.execute("ALTER TABLE captures ADD COLUMN url TEXT")
        self.db.execute("ALTER TABLE captures ADD COLUMN content_hash TEXT")
        self.db.commit()
        self.binding = {"libraryID": str(uuid.uuid4()), "serviceID": str(uuid.uuid4())}
        self.output = self.source.parent / "content-transfer"

    def tearDown(self):
        self.fixture.tearDown()

    def add_icons(self):
        self.db.executescript("""CREATE TABLE website_icon_jobs(id TEXT PRIMARY KEY,origin TEXT,content BLOB,revision INTEGER);
            CREATE TABLE capture_icon_origins(capture_id INTEGER PRIMARY KEY,origin_id TEXT);""")
        origin = "https://www.example.com"
        self.db.execute("UPDATE captures SET kind='link',url=?,content_hash=? WHERE id=81",
                        (origin + "/synthetic", hashlib.sha256(origin.encode()).hexdigest()))
        data = png()
        fingerprint = hashlib.sha256(data).hexdigest()
        self.content = {"blob": {"digest": fingerprint, "byteCount": len(data)},
                        "normalizerVersion": 1, "fetchedAt": 123456789.5}
        self.icon_id = hashlib.sha256(origin.encode()).hexdigest()
        self.db.execute("INSERT INTO website_icon_jobs VALUES(?,?,?,0)",
                        (self.icon_id, origin, migration.encode(self.content)))
        self.db.execute("INSERT INTO capture_icon_origins VALUES(81,?)", (self.icon_id,))
        self.db.execute("INSERT INTO website_icon_jobs VALUES(?,?,?,0)",
                        ("unreachable", "https://unreachable.example.com", migration.encode(self.content)))
        self.db.commit()
        directory = self.source / "assets" / "website-icons"
        directory.mkdir()
        (directory / fingerprint).write_bytes(data)

    def prepared(self):
        snapshot.capture_quiesced(self.source, self.fixture.archive)
        snapshot.restore_copy(self.fixture.archive, self.fixture.work)
        snapshot.backfill(self.fixture.work)
        prepared = self.source.parent / "prepared-icons"
        snapshot.archive_prepared(self.fixture.work, prepared)
        return prepared

    def test_v2_export_copies_only_reachable_digest_assets_and_retains_source(self):
        self.add_icons()
        before = migration.inventory(self.source)
        prepared = self.prepared()
        result = snapshot.export_content(prepared, self.output, self.binding)
        self.assertEqual(result["version"], 2)
        self.assertEqual(len(result["captures"]), 2)
        self.assertEqual(len(result["websiteIcons"]), 1)
        self.assertEqual(result["websiteIcons"][0]["origin"]["canonicalHTTPSOrigin"], "https://www.example.com")
        self.assertEqual(result["websiteIcons"][0]["content"], self.content)
        self.assertEqual((self.output / "assets" / self.content["blob"]["digest"]).read_bytes(), png())
        self.assertEqual(json.loads((self.output / "snapshot.json").read_bytes()), result)
        self.assertEqual(migration.inventory(self.source), before)
        again = snapshot.export_content(prepared, self.source.parent / "second-transfer", self.binding)
        self.assertEqual(again, result)

    def test_legacy_export_omits_icon_fields(self):
        prepared = self.prepared()
        result = snapshot.export_content(prepared, self.output, self.binding)
        self.assertEqual(result["version"], 1)
        self.assertNotIn("websiteIcons", result)
        with contextlib.closing(sqlite3.connect(prepared / "payload" / snapshot.DATABASE)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sync_capture_ids").fetchone()[0], 2)

    def test_empty_icon_namespace_exports_v2_without_deleting_icons(self):
        self.db.executescript("""CREATE TABLE website_icon_jobs(id TEXT PRIMARY KEY,origin TEXT,content BLOB,revision INTEGER);
            CREATE TABLE capture_icon_origins(capture_id INTEGER PRIMARY KEY,origin_id TEXT);""")
        result = snapshot.export_content(self.prepared(), self.output, self.binding)
        self.assertEqual(result["version"], 2)
        self.assertEqual(result["websiteIcons"], [])

    def test_direct_import_refuses_icons_before_any_authority_mutation(self):
        self.add_icons()
        prepared = self.prepared()
        authority, binding = self.fixture.fixture.authority()
        before = migration.inventory(authority)
        manifest = snapshot.verify_prepared(prepared)
        with self.assertRaisesRegex(migration.PreparationError, "export-content"):
            migration._import_initial_mac(prepared, manifest, authority, binding, str(uuid.uuid4()),
                                          "server.sqlite", None, "assets", snapshot.verify_prepared)
        self.assertEqual(migration.inventory(authority), before)

    def test_export_failure_removes_only_new_transfer_and_preserves_archive(self):
        self.add_icons()
        prepared = self.prepared()
        before = migration.inventory(prepared)
        with mock.patch.object(snapshot.shutil, "copyfileobj", side_effect=OSError("synthetic copy failure")):
            with self.assertRaises(OSError):
                snapshot.export_content(prepared, self.output, self.binding)
        self.assertFalse(self.output.exists())
        self.assertEqual(migration.inventory(prepared), before)

    def test_invalid_origin_metadata_and_missing_png_fail_before_export(self):
        self.add_icons()
        for statement, arguments in [
            ("UPDATE website_icon_jobs SET origin=? WHERE id=?", ("https://example.com", self.icon_id)),
            ("UPDATE website_icon_jobs SET content=? WHERE id=?", (b"{}", self.icon_id)),
        ]:
            with self.subTest(statement=statement):
                self.db.execute("SAVEPOINT malformed_icon")
                self.db.execute(statement, arguments)
                with self.assertRaises(migration.PreparationError):
                    migration.local_website_icons(self.db, self.source)
                self.db.execute("ROLLBACK TO malformed_icon")
                self.db.execute("RELEASE malformed_icon")
        (self.source / "assets" / "website-icons" / self.content["blob"]["digest"]).unlink()
        with self.assertRaises(migration.PreparationError):
            migration.local_website_icons(self.db, self.source)


if __name__ == "__main__":
    unittest.main()
