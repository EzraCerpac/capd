#!/usr/bin/env python3
"""Import an approved Mac snapshot into a disposable local authority; report counts only."""

import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import sqlite3
import subprocess
import time
import uuid

import mac_library_snapshot as snapshot
import synthetic_library_migration as migration


def require(condition, reason):
    if not condition:
        raise migration.PreparationError(reason)


class BaselineResourceLimit(migration.PreparationError):
    pass


def canonical_uuid(value):
    require(isinstance(value, str), "baseline identity is not a UUID")
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError as error:
        raise migration.PreparationError("baseline identity is not a UUID") from error


def device_sequences(value):
    if isinstance(value, dict):
        pairs = list(value.items())
    else:
        require(isinstance(value, list) and len(value) % 2 == 0, "invalid baseline device sequences")
        pairs = zip(value[::2], value[1::2])
    result = {}
    for identity, sequence in pairs:
        identity = canonical_uuid(identity)
        require(identity not in result and type(sequence) is int and 0 <= sequence <= 2**63 - 1,
                "invalid baseline device sequences")
        result[identity] = sequence
    return result


class LocalHost:
    def __init__(self, binary, root, binding, device):
        self.binary, self.root, self.binding, self.device = binary, root, binding, device
        self.credential = secrets.token_hex(32)
        self.config = root / "temporary-enrollment.json"
        self.log = root / "local-host.log"
        self.process = None
        self.output = None
        self.port = None
        config = {"serviceID": binding["serviceID"], "enrollments": [
            {"libraryID": binding["libraryID"], "deviceID": device,
             "credentialSHA256": hashlib.sha256(self.credential.encode()).hexdigest(), "revoked": False}]}
        self.config.write_bytes(migration.encode(config))
        self.config.chmod(0o600)

    def start(self):
        require(self.process is None, "owned host is already started")
        self.output = self.log.open("a")
        offset = self.log.stat().st_size
        self.process = subprocess.Popen(
            [str(self.binary), "--config", str(self.config), "--data-dir", str(self.root / "server"), "--port", "0"],
            stdout=self.output, stderr=self.output)
        deadline = time.monotonic() + 15
        while self.process.poll() is None and time.monotonic() < deadline:
            text = self.log.read_text()[offset:]
            for line in text.splitlines():
                if line.startswith("capd-sync-server ready 127.0.0.1:"):
                    self.port = int(line.rsplit(":", 1)[1])
                    return
            time.sleep(0.05)
        raise migration.PreparationError("owned loopback host did not become ready")

    def baseline_page(self, after, limit, cursor):
        page_request = {"limit": limit}
        if after is not None:
            page_request["after"] = after
        if cursor is not None:
            page_request["expectedCursor"] = cursor
        envelope = {"version": 1, "expectedServiceID": self.binding["serviceID"],
                    "expectedLibraryID": self.binding["libraryID"], "expectedDeviceID": self.device,
                    "action": {"baselinePage": page_request}}
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request("POST", "/v1/sync", body=migration.encode(envelope), headers={
                "Content-Type": "application/json", "Authorization": "Bearer " + self.credential})
            response = connection.getresponse()
            data = response.read(16_777_217)
            if len(data) > 16_777_216:
                raise BaselineResourceLimit("baseline page exceeds response limit")
            reply = json.loads(data)
            require(isinstance(reply, dict) and type(reply.get("version")) is int
                    and reply["version"] == 1, "invalid baseline reply")
            result = reply.get("result")
            require(isinstance(result, dict), "invalid baseline result")
            if response.status != 200 and reply.get("principal") is None and result == {"failure": {"_0": "resourceLimit"}}:
                raise BaselineResourceLimit("baseline page exceeds response limit")
            expected = dict(self.binding, deviceID=self.device)
            require(response.status == 200 and reply.get("principal") == expected
                    and type(reply.get("metadataContractVersion")) is int
                    and reply["metadataContractVersion"] == 1, "baseline scope or contract mismatch")
            require(set(result) == {"baseline"} and isinstance(result["baseline"], dict)
                    and set(result["baseline"]) == {"_0"}, "invalid baseline result")
            return result["baseline"]["_0"]
        finally:
            connection.close()

    def baseline(self, expected_count):
        after, first, captures, limit = None, None, [], 100
        while True:
            try:
                page = self.baseline_page(after, limit, first["cursor"] if first else None)
            except BaselineResourceLimit:
                if limit == 1:
                    raise
                limit = max(1, limit // 2)
                continue
            require(isinstance(page, dict), "invalid baseline page")
            cursor, total = page.get("cursor"), page.get("totalCaptureCount")
            require(type(cursor) is int and 0 <= cursor <= 2**63 - 1
                    and type(total) is int and total == expected_count, "baseline cursor or count mismatch")
            sequences = device_sequences(page.get("deviceSequences"))
            rows = page.get("captures")
            require(isinstance(rows, list) and len(rows) == min(limit, total - len(captures)),
                    "baseline page count mismatch")
            require(first is None or (cursor == first["cursor"] and sequences == first_sequences),
                    "baseline changed between pages")
            previous = after
            for row in rows:
                require(isinstance(row, dict), "invalid baseline capture")
                identity = canonical_uuid(row.get("id"))
                require(row["id"] == identity and (previous is None or identity > previous),
                        "baseline identities are not strictly ordered")
                previous = identity
            if first is None:
                first, first_sequences = page, sequences
            captures.extend(rows)
            if len(captures) == total:
                return dict(first, captures=captures)
            after = previous

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            try:
                code = self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
                raise migration.PreparationError("owned host required forced stop")
            finally:
                self.process = None
                self.port = None
                self.output.close()
                self.output = None
            require(code == 0, "owned host did not stop cleanly")

    def clean(self):
        try:
            self.stop()
        finally:
            self.config.unlink(missing_ok=True)
            if self.log.exists():
                require(self.credential not in self.log.read_text(), "credential appeared in owned log")
            self.credential = None


def run(archive, root, binary):
    os.umask(0o077)
    archive, root = snapshot.canonical(archive), snapshot.canonical(root)
    manifest = snapshot.verify_raw(archive)
    require(archive.parent == root, "snapshot must belong to the private run")
    work, restored = root / "working-copy", root / "restore-check"
    first = snapshot.restore_copy(archive, work)
    second = snapshot.restore_copy(archive, restored)
    require(first["sourceSQL"] == second["sourceSQL"], "restored databases differ")
    with contextlib.closing(migration.connect(work / snapshot.DATABASE, readonly=True)) as db:
        original_rows = db.execute("SELECT * FROM captures ORDER BY id").fetchall()
        original_fts = db.execute("SELECT rowid,* FROM captures_fts ORDER BY rowid").fetchall()
        kinds = dict(db.execute("SELECT kind,COUNT(*) FROM captures GROUP BY kind"))
        capture_count = len(original_rows)
    identities = snapshot.backfill(work)
    require(len(identities) == capture_count, "backfill identity count differs")
    with contextlib.closing(migration.connect(work / snapshot.DATABASE, readonly=True)) as db:
        require(db.execute("SELECT * FROM captures ORDER BY id").fetchall() == original_rows,
                "backfill changed capture rows")
        require(db.execute("SELECT rowid,* FROM captures_fts ORDER BY rowid").fetchall() == original_fts,
                "backfill changed FTS rows")
        sidecars = db.execute("SELECT global_id,payload FROM sync_legacy_snapshot ORDER BY local_id").fetchall()
    prepared = root / "prepared-archive"
    snapshot.archive_prepared(work, prepared)
    binding = {"libraryID": str(uuid.uuid4()).upper(), "serviceID": str(uuid.uuid4()).upper()}
    device, import_id = str(uuid.uuid4()).upper(), str(uuid.uuid4())
    expected = {identity: migration.imported_capture(identity, json.loads(payload), uuid.UUID(import_id))
                for identity, payload in sidecars}
    host = LocalHost(binary, root, binding, device)
    try:
        host.start()
        require(host.baseline(0)["captures"] == [], "new authority is not empty")
        host.stop()
        authority = root / "server" / binding["libraryID"].lower()
        owner = {"format": snapshot.PREPARED_FORMAT, "snapshotID": manifest["snapshotID"],
                 "authorityRoot": str(authority), "binding": binding}
        (authority / snapshot.COPY_MARKER).write_bytes(migration.encode(owner))
        result = snapshot.import_copy(prepared, authority, binding, import_id)
        repeated = snapshot.import_copy(prepared, authority, binding, import_id)
        require(result["count"] == capture_count and repeated["replayed"], "import count or repeat mismatch")
        with contextlib.closing(migration.connect(authority / "authority.sqlite", readonly=True)) as db:
            require(db.execute("SELECT COUNT(*) FROM sync_receipts").fetchone()[0] == 0, "unexpected device receipts")
            require(db.execute("SELECT COUNT(*) FROM sync_devices").fetchone()[0] == 0, "unexpected device history")
            require(db.execute("SELECT COUNT(*) FROM sync_imported_legacy").fetchone()[0] == capture_count,
                    "legacy preservation sidecar count mismatch")
        host.start()
        baseline = host.baseline(capture_count)
        received = {row["id"]: row for row in baseline["captures"]}
        require(received == expected, "HTTP baseline differs from complete imported records")
        require(baseline["cursor"] == 1 and not baseline["deviceSequences"], "import fabricated device history")
        host.stop()
        snapshot.verify_raw(archive)
        snapshot.verify_prepared(prepared)
        report = {"snapshotID": manifest["snapshotID"], "captureCount": capture_count, "kinds": kinds,
                  "assetFileCount": sum(v is not None for k,v in manifest["files"].items() if k.startswith("assets/")),
                  "sourceRowsAndFTSUnchangedInWorkingCopy": True, "fullRestoreSQLMatch": True,
                  "identityCount": len(identities), "legacySidecarCount": capture_count,
                  "allImportedFieldsMatchHTTPBaseline": True, "authorityCursor": 1,
                  "authorityDeviceHistoryCount": 0, "authorityDeviceReceiptCount": 0,
                  "idempotentImport": True, "rawArchiveVerified": True,
                  "noLiveBindingOrNASUpload": True, "binding": binding}
    finally:
        host.clean()
    report["ownedHostStopped"] = True
    report["temporaryCredentialConfigRemoved"] = not host.config.exists()
    (root / "dry-run-report.json").write_text(json.dumps(report, indent=2))
    (root / "dry-run-report.json").chmod(0o600)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--host-binary", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args.snapshot, args.run_root, args.host_binary.resolve())
    except Exception as error:
        print(json.dumps({"dryRun": "failed", "errorType": type(error).__name__}), flush=True)
        raise SystemExit(1)
