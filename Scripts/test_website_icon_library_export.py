import contextlib
import hashlib
import json
import sqlite3
import struct
import sys
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

    def add_icons(self, origin="https://www.example.com", capture_url=None):
        self.db.executescript("""CREATE TABLE website_icon_jobs(id TEXT PRIMARY KEY,origin TEXT,content BLOB,revision INTEGER);
            CREATE TABLE capture_icon_origins(capture_id INTEGER PRIMARY KEY,origin_id TEXT);""")
        self.db.execute("UPDATE captures SET kind='link',url=?,content_hash=? WHERE id=81",
                        (capture_url or origin + "/synthetic", hashlib.sha256(origin.encode()).hexdigest()))
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

    @unittest.skipUnless(sys.platform == "darwin", "IDN parity uses macOS Foundation")
    def test_origin_identity_matches_foundation(self):
        cases = [
            ("https://bücher.de/path?q=1#part", "https://xn--bcher-kva.de"),
            ("https://XN--BCHER-KVA.DE:443/path", "https://xn--bcher-kva.de"),
            ("https://WWW.例え.テスト:443/path", "https://www.xn--r8jz45g.xn--zckzah"),
            ("https://faß.de", "https://xn--fa-hia.de"),
            ("https://BÜCHER。DE:443/path", "https://xn--bcher-kva.de"),
            ("https://bu\u0308cher.de", "https://xn--bcher-kva.de"),
            ("https://ｅｘａｍｐｌｅ．ｃｏｍ", "https://example.com"),
            ("https://example%2ecom/path", "https://example.com"),
            ("https://%65xample.com", "https://example.com"),
            ("https://WWW.EXAMPLE.COM:443/path", "https://www.example.com"),
        ]
        for url, expected in cases:
            with self.subTest(url=url):
                self.assertEqual(migration.website_origin(url), expected)
                self.assertEqual(migration.website_origin(expected), expected)

    @unittest.skipUnless(sys.platform == "darwin", "IDN parity uses macOS Foundation")
    def test_origin_refusals_match_foundation(self):
        for url in [
            "https://xn--.de", "https://xn--bcher-kva.local", "https://bücher.local",
            "https://user@bücher.de", "https://bücher.de:444", "http://bücher.de",
            "https://１２７.０.０.１", "https://[::1]", "https://b%C3%BCcher.de",
            "https://%ZZ.de", "https://%FF.de", "https://bücher.de.", "https://bücher..de",
            "https://bücher.ｌｏｃａｌ", "https://2130706433", "https://0x7f.0.0.0x1",
        ]:
            with self.subTest(url=url):
                self.assertIsNone(migration.website_origin(url))

    @unittest.skipUnless(sys.platform == "darwin", "IDN parity uses macOS Foundation")
    def test_idn_icon_export_preserves_canonical_record_and_verified_png(self):
        origin = "https://xn--bcher-kva.de"
        self.add_icons(origin, "https://bücher.de/synthetic\tpath?q=one\ntwo")
        before = migration.inventory(self.source)
        result = snapshot.export_content(self.prepared(), self.output, self.binding)
        self.assertEqual(result["websiteIcons"][0]["origin"]["canonicalHTTPSOrigin"], origin)
        self.assertEqual(result["websiteIcons"][0]["content"], self.content)
        self.assertEqual((self.output / "assets" / self.content["blob"]["digest"]).read_bytes(), png())
        self.assertEqual(migration.inventory(self.source), before)

    def test_escaped_ascii_live_icon_exports_with_unchanged_identity(self):
        origin = "https://www.example.com"
        self.add_icons(origin, "https://%77ww.example%2ecom/synthetic")
        result = snapshot.export_content(self.prepared(), self.output, self.binding)
        self.assertEqual(result["websiteIcons"][0]["origin"]["canonicalHTTPSOrigin"], origin)
        self.assertEqual(result["websiteIcons"][0]["content"], self.content)

    def test_non_mac_ascii_remains_standalone_and_idn_fails_closed(self):
        with mock.patch.object(migration.sys, "platform", "linux"):
            self.assertEqual(migration.website_origin("https://%65xample.com"), "https://example.com")
            self.assertEqual(migration.website_origin("https://xn--fa-hia.de"), "https://xn--fa-hia.de")
            self.assertIsNone(migration.website_origin("https://0x7f.0.0.0x1"))
            self.assertIsNone(migration.website_origin("https://xn--.de"))
            with self.assertRaisesRegex(migration.PreparationError, "requires macOS Foundation"):
                migration.website_origin("https://faß.de")

    def test_foundation_unavailable_refuses_without_mutating_source(self):
        if sys.platform != "darwin":
            self.skipTest("Foundation is a macOS exporter dependency")
        import foundation_website_origin
        self.add_icons()
        prepared = self.prepared()
        before = migration.inventory(prepared)
        with mock.patch.object(foundation_website_origin, "host", side_effect=OSError("synthetic missing Foundation")):
            with self.assertRaisesRegex(migration.PreparationError, "requires macOS Foundation"):
                snapshot.export_content(prepared, self.output, self.binding)
        self.assertFalse(self.output.exists())
        self.assertEqual(migration.inventory(prepared), before)

    def test_foundation_cache_is_bounded_and_long_urls_are_not_retained(self):
        import foundation_website_origin
        foundation_website_origin._cached_host.cache_clear()
        url = "https://example.com"
        long_url = url + "/" + "x" * 4096
        with mock.patch.object(foundation_website_origin, "_host", return_value="example.com") as parse:
            self.assertEqual(foundation_website_origin.host(url), "example.com")
            foundation_website_origin.host(url)
            foundation_website_origin.host(long_url)
            foundation_website_origin.host(long_url)
            self.assertEqual(parse.call_count, 3)
            for index in range(300):
                foundation_website_origin.host(f"https://site{index}.com")
            self.assertEqual(foundation_website_origin._cached_host.cache_info().currsize, 256)
        foundation_website_origin._cached_host.cache_clear()

    @unittest.skipUnless(sys.platform == "darwin", "URL parity uses macOS Foundation")
    def test_path_query_controls_preserve_foundation_origin(self):
        for url, expected in [
            ("https://example.com/path\npart", "https://example.com"),
            ("https://example.com/?q=one\ttwo", "https://example.com"),
            ("https://bücher.de/path\tpart?q=one\ntwo", "https://xn--bcher-kva.de"),
        ]:
            with self.subTest(url=url):
                self.assertEqual(migration.website_origin(url), expected)
        for url in ["https://exam\tple.com/path", "https://example.com\n/path"]:
            with self.subTest(url=url):
                self.assertIsNone(migration.website_origin(url))

    def test_nul_input_is_refused_before_foundation(self):
        import foundation_website_origin
        with mock.patch.object(foundation_website_origin, "host") as parse:
            for url in ["https://example.com\0.other", "https://example.com/path\0suffix"]:
                self.assertIsNone(migration.website_origin(url))
            parse.assert_not_called()

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
