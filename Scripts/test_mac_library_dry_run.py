import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid

import mac_library_dry_run as dry_run
import mac_library_snapshot as snapshot
import synthetic_library_migration as migration
import test_mac_library_snapshot as fixtures


class BaselinePageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="capd-dry-run-pages-")
        self.addCleanup(temporary.cleanup)
        self.host = dry_run.LocalHost(Path("unused"), Path(temporary.name),
                                     {"serviceID": str(uuid.uuid4()).upper(),
                                      "libraryID": str(uuid.uuid4()).upper()}, str(uuid.uuid4()).upper())
        self.host.port = 1
        self.addCleanup(self.host.clean)
        self.calls, self.connections = [], []

    def page(self, ids, total, cursor=9, sequences=None):
        return {"cursor": cursor, "totalCaptureCount": total, "deviceSequences": sequences or [],
                "captures": [{"id": str(uuid.UUID(int=identity)).upper()} for identity in ids]}

    def reply(self, page, **fields):
        return dict({"version": 1, "principal": dict(self.host.binding, deviceID=self.host.device),
                     "metadataContractVersion": 1, "result": {"baseline": {"_0": page}}}, **fields)

    def connection_factory(self, replies):
        owner = self

        class Connection:
            def __init__(self, *args, **kwargs):
                self.closed = False
                owner.connections.append(self)

            def request(self, method, path, body, headers):
                owner.calls.append(json.loads(body)["action"])

            def getresponse(self):
                if not replies:
                    raise AssertionError("unexpected additional request")
                self.status, self.data = replies.pop(0)
                if isinstance(self.data, dict):
                    self.data = migration.encode(self.data)
                return self

            def read(self, limit):
                return self.data[:limit]

            def close(self):
                self.closed = True

        return Connection

    def fetch(self, replies, count):
        with mock.patch.object(dry_run.http.client, "HTTPConnection", self.connection_factory(replies)):
            try:
                return self.host.baseline(count)
            finally:
                self.assertTrue(all(connection.closed for connection in self.connections))

    def test_resource_limit_reduces_pages_and_pins_metadata_and_last_identity(self):
        failure = {"version": 1, "result": {"failure": {"_0": "resourceLimit"}}}
        first, second = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        replies = [(503, failure)] * 6 + [
            (200, self.reply(self.page([1], 3, sequences=[first, 9, second, 10]))),
            (200, self.reply(self.page([2], 3, sequences=[second, 10, first, 9]))),
            (200, self.reply(self.page([3], 3, sequences=[first, 9, second, 10])))]
        baseline = self.fetch(replies, 3)
        self.assertEqual(len(baseline["captures"]), 3)
        self.assertEqual([action["baselinePage"]["limit"] for action in self.calls],
                         [100, 50, 25, 12, 6, 3, 1, 1, 1])
        self.assertEqual(self.calls[-1], {"baselinePage": {
            "limit": 1, "expectedCursor": 9, "after": str(uuid.UUID(int=2)).upper()}})
        self.assertNotIn("expectedCursor", self.calls[0]["baselinePage"])

    def test_empty_baseline_is_one_verified_page(self):
        self.assertEqual(self.fetch([(200, self.reply(self.page([], 0)))], 0)["captures"], [])
        self.assertEqual(self.calls, [{"baselinePage": {"limit": 100}}])

    def test_resource_retry_after_first_page_preserves_cursor_and_continuation(self):
        failure = {"version": 1, "result": {"failure": {"_0": "resourceLimit"}}}
        baseline = self.fetch([(200, self.reply(self.page(range(1, 101), 101))),
                               (503, failure), (200, self.reply(self.page([101], 101)))], 101)
        self.assertEqual(len(baseline["captures"]), 101)
        self.assertEqual(self.calls[-2:], [{"baselinePage": {
            "limit": limit, "expectedCursor": 9, "after": str(uuid.UUID(int=100)).upper()}}
            for limit in (100, 50)])

    def test_resource_limit_at_one_is_bounded_and_fails(self):
        failure = {"version": 1, "result": {"failure": {"_0": "resourceLimit"}}}
        with self.assertRaises(dry_run.BaselineResourceLimit):
            self.fetch([(503, failure)] * 7, 2)
        self.assertEqual(len(self.calls), 7)

    def test_oversized_page_retries_at_smaller_limit(self):
        baseline = self.fetch([(200, b"x" * 16_777_217),
                               (200, self.reply(self.page([1], 1)))], 1)
        self.assertEqual(len(baseline["captures"]), 1)
        self.assertEqual(self.calls[-1], {"baselinePage": {"limit": 50}})

    def test_malformed_first_pages_fail_without_retry(self):
        pages = [self.page([], 1), self.page([1, 2], 1), self.page([1], 2),
                 self.page([2, 1], 2), self.page([1, 1], 2),
                 self.page([1], 1, cursor=True), self.page([1], True),
                 self.page([1], 1, sequences=[str(uuid.uuid4()), -1])]
        pages += [dict(self.page([1], 1), captures=[{"id": "invalid"}]),
                  dict(self.page([1], 1), captures=[{"id": None}])]
        for page in pages:
            with self.subTest(pageKeys=list(page)):
                before = len(self.calls)
                with self.assertRaises(migration.PreparationError):
                    self.fetch([(200, self.reply(page))], 1 if page["totalCaptureCount"] != 2 else 2)
                self.assertEqual(len(self.calls), before + 1)

    def test_changed_or_nonprogressing_second_pages_fail(self):
        failure = {"version": 1, "result": {"failure": {"_0": "resourceLimit"}}}
        second_pages = [self.page([2], 2, cursor=10), self.page([2], 3), self.page([1], 2),
                        self.page([], 2), self.page([2], 2, sequences=[str(uuid.uuid4()), 1])]
        for page in second_pages:
            with self.subTest(pageKeys=list(page)), self.assertRaises(migration.PreparationError):
                self.fetch([(503, failure)] * 6 + [(200, self.reply(self.page([1], 2))),
                                                 (200, self.reply(page))], 2)

    def test_scope_contract_and_nonresource_errors_do_not_retry(self):
        replies = [(200, self.reply(self.page([1], 1), principal={})),
                   (200, self.reply(self.page([1], 1), metadataContractVersion=2)),
                   (503, {"version": 1, "result": {"failure": {"_0": "unavailable"}}}),
                   (200, {"version": 1, "result": {"failure": {"_0": "resourceLimit"}}}),
                   (503, self.reply(self.page([1], 1), result={"failure": {"_0": "resourceLimit"}})),
                   (200, self.reply(self.page([1], 1), result={"okay": {}}))]
        for reply in replies:
            with self.subTest(status=reply[0]):
                before = len(self.calls)
                with self.assertRaises(migration.PreparationError):
                    self.fetch([reply], 1)
                self.assertEqual(len(self.calls), before + 1)


class LargeLibraryDryRunTests(unittest.TestCase):
    def test_complete_large_library_and_failure_cleanup(self):
        self.run_library(malformed=False)

    def test_malformed_page_stops_owned_host_and_removes_credentials_without_report(self):
        self.run_library(malformed=True)

    def run_library(self, malformed):
        fixture = fixtures.RealSourceAdapterTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        body = "x" * (128 * 1024)
        fixture.fixture.db.execute("UPDATE captures SET body=?", (body,))
        fixture.fixture.db.executemany(
            "INSERT INTO captures(kind,title,seen_count,created_at,body) VALUES(?,?,?,?,?)",
            [("text", f"Large capture {index}", 1, "2024-01-01", body) for index in range(100)])
        fixture.fixture.db.commit()
        capture_count = fixture.fixture.db.execute("SELECT COUNT(*) FROM captures").fetchone()[0]
        before = snapshot.source_files(fixture.source)
        snapshot.capture_quiesced(fixture.source, fixture.archive)
        binary = Path(__file__).resolve().parents[1] / "Packages/CapdSyncServer/.build/debug/capd-sync-server"
        hosts = []
        host_type = dry_run.LocalHost

        def host(*args):
            result = host_type(*args)
            hosts.append(result)
            return result

        page_method = host_type.baseline_page
        malformed_pages = []
        imported_pages = []

        def page(host, *args):
            result = page_method(host, *args)
            if result["cursor"] == 1:
                imported_pages.append((args, result))
                if malformed:
                    malformed_pages.append(result)
                    return dict(result, cursor=True)
            return result

        with mock.patch.object(dry_run, "LocalHost", side_effect=host), \
                mock.patch.object(host_type, "baseline_page", page):
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    if malformed:
                        with self.assertRaises(migration.PreparationError):
                            dry_run.run(fixture.archive, fixture.source.parent, binary)
                    else:
                        dry_run.run(fixture.archive, fixture.source.parent, binary)
            finally:
                self.assertEqual(len(hosts), 1)
                self.assertIsNone(hosts[0].process)
                self.assertIsNone(hosts[0].output)
                self.assertIsNone(hosts[0].credential)
                self.assertFalse(hosts[0].config.exists())
                self.assertEqual(snapshot.source_files(fixture.source), before)
        authority = fixture.source.parent / "server" / hosts[0].binding["libraryID"].lower()
        with contextlib.closing(migration.connect(authority / "authority.sqlite", readonly=True)) as db:
            sizes = [row[0] for row in db.execute("SELECT length(payload) FROM sync_records")]
        self.assertEqual(capture_count, 102)
        self.assertEqual(len(sizes), capture_count)
        self.assertGreater(sum(sizes), 8 * 1024 * 1024)
        baseline_bytes = (2 + sum(sizes) + capture_count - 1
                          + capture_count * migration.IMPORTED_CAPTURE_COUNTER_GROWTH_BYTES)
        self.assertLess(baseline_bytes, migration.MAXIMUM_IMPORTED_BASELINE_BYTES)
        self.assertLess(max(sizes), migration.MAXIMUM_IMPORTED_CAPTURE_BYTES)
        self.assertEqual(imported_pages[0][0], (None, 100, None))
        self.assertEqual(len(imported_pages[0][1]["captures"]), 100)
        self.assertTrue(all(page["totalCaptureCount"] == capture_count for _, page in imported_pages))
        if malformed:
            self.assertEqual(len(imported_pages), 1)
            self.assertEqual(len(malformed_pages), 1)
            self.assertFalse((fixture.source.parent / "dry-run-report.json").exists())
            return
        self.assertEqual([len(page["captures"]) for _, page in imported_pages], [100, 2])
        self.assertEqual(imported_pages[1][0], (imported_pages[0][1]["captures"][-1]["id"], 100, 1))
        report = json.loads((fixture.source.parent / "dry-run-report.json").read_bytes())
        self.assertEqual(report["captureCount"], capture_count)
        self.assertTrue(report["allImportedFieldsMatchHTTPBaseline"])
        self.assertTrue(report["ownedHostStopped"])
        self.assertTrue(report["temporaryCredentialConfigRemoved"])


if __name__ == "__main__":
    unittest.main()
