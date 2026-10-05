#!/usr/bin/env python3
"""Offline preparation for explicitly marked synthetic Capd libraries only."""

import argparse
import base64
import contextlib
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unicodedata
import uuid

MARKER = ".capd-synthetic-fixture"
MARKER_BYTES = b"synthetic-capd-library-v1\n"
FORMAT = "capd-synthetic-backup-v1"
MAXIMUM_SHARED_FRAME_BYTES = 16_777_216
# Reserve more than the shared single-record envelopes and counter/date encoding growth.
MAXIMUM_IMPORTED_CAPTURE_BYTES = MAXIMUM_SHARED_FRAME_BYTES - 65_536


class PreparationError(Exception):
    pass


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def inventory(root):
    result = {}
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise PreparationError("symlinks are not permitted")
            if not path.is_dir() and not path.is_file():
                raise PreparationError("only regular files and directories are permitted")
            relative = path.relative_to(root).as_posix()
            result[relative] = None if path.is_dir() else digest(path)
    return result


def fixture(root):
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir():
        raise PreparationError(f"fixture root must be an existing canonical directory: {root} (resolved {root.resolve()})")
    inventory(root)
    if not (root / MARKER).is_file() or (root / MARKER).read_bytes() != MARKER_BYTES:
        raise PreparationError("an explicit synthetic fixture marker is required")
    return root


def database_name(name, label="database"):
    if not name or Path(name).name != name or name in (".", "..", MARKER):
        raise PreparationError(label + " name must be a single filename")
    return name


def separate(source, destination):
    destination = Path(destination).absolute()
    if destination.parent.resolve() != destination.parent:
        raise PreparationError("destination parent must be canonical")
    if destination == source or source in destination.parents or destination in source.parents:
        raise PreparationError("source and destination must be separate trees")
    return destination


def connect(path, readonly=False):
    return sqlite3.connect(path.as_uri() + ("?mode=ro" if readonly else "?mode=rw"), uri=True)


def sql_signature(connection):
    h = hashlib.sha256()
    for pragma in ("user_version", "application_id", "encoding", "auto_vacuum", "page_size"):
        h.update(encode([pragma, connection.execute("PRAGMA " + pragma).fetchone()[0]]))
    for statement in connection.iterdump():
        h.update(statement.encode())
        h.update(b"\n")
    return h.hexdigest()


def integrity(connection):
    if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise PreparationError("SQLite integrity check failed")
    if connection.execute("PRAGMA foreign_key_check").fetchall():
        raise PreparationError("SQLite foreign key check failed")


def asset_inventory(root, name):
    excluded = {name, name + "-wal", name + "-shm", name + "-journal"}
    return {key: value for key, value in inventory(root).items() if key not in excluded}


def inject(callback, stage):
    if callback:
        callback(stage)


def backup(source, destination, name="captures.sqlite", failure=None):
    """The caller must stop all fixture asset writers for the complete call."""
    source = fixture(source)
    name = database_name(name)
    destination = separate(source, destination)
    with contextlib.closing(connect(source / name)) as lock:
        lock.execute("BEGIN IMMEDIATE")
        with contextlib.closing(connect(source / name, readonly=True)) as reader:
            integrity(reader)
            before = asset_inventory(source, name)
            signature = sql_signature(reader)
            if destination.exists():
                manifest = verify(destination)
                if (manifest["database"] != name or manifest["sourceSQL"] != signature
                        or manifest["sourceFiles"] != before):
                    raise PreparationError("existing backup belongs to a different snapshot")
                return manifest
            destination.mkdir()
            try:
                payload = destination / "payload"
                payload.mkdir()
                with contextlib.closing(sqlite3.connect(payload / name)) as target:
                    reader.backup(target)
                    target.execute("PRAGMA journal_mode=DELETE")
                    integrity(target)
                    if sql_signature(target) != signature:
                        raise PreparationError("SQLite snapshot changed")
                inject(failure, "database")
                for relative, checksum in before.items():
                    target = payload / relative
                    if checksum is None:
                        target.mkdir(parents=True, exist_ok=True)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(source / relative, target)
                inject(failure, "assets")
                if asset_inventory(source, name) != before or asset_inventory(payload, name) != before:
                    raise PreparationError("asset tree changed during backup")
                manifest = {"format": FORMAT, "database": name, "sourceSQL": signature,
                            "sourceFiles": before, "files": inventory(payload)}
                inject(failure, "publish")
                (destination / "manifest.json").write_bytes(encode(manifest))
                verify(destination)
                return manifest
            except BaseException:
                shutil.rmtree(destination)
                raise


def verify(archive):
    archive = Path(archive).absolute()
    if archive.resolve() != archive:
        raise PreparationError("archive must be canonical")
    files = inventory(archive)
    if "manifest.json" not in files:
        raise PreparationError("backup is incomplete")
    manifest = json.loads((archive / "manifest.json").read_bytes())
    if manifest.get("format") != FORMAT:
        raise PreparationError("unsupported backup format")
    name = database_name(manifest["database"])
    payload = fixture(archive / "payload")
    if inventory(payload) != manifest["files"]:
        raise PreparationError("backup file inventory or checksum mismatch")
    if asset_inventory(payload, name) != manifest["sourceFiles"]:
        raise PreparationError("backup asset inventory mismatch")
    with contextlib.closing(connect(payload / name, readonly=True)) as db:
        integrity(db)
        if sql_signature(db) != manifest["sourceSQL"]:
            raise PreparationError("backup SQLite contents mismatch")
    return manifest


def restore(archive, destination, failure=None):
    """Publishes a fresh fixture only; replacement of an existing library is forbidden."""
    archive = Path(archive).absolute()
    manifest = verify(archive)
    destination = separate(archive, destination)
    destination.mkdir()
    staging = Path(tempfile.mkdtemp(prefix=".capd-restore-", dir=destination.parent))
    try:
        shutil.copytree(archive / "payload", staging, dirs_exist_ok=True)
        inject(failure, "restore-copy")
        if inventory(staging) != manifest["files"]:
            raise PreparationError("restored files mismatch")
        with contextlib.closing(connect(staging / manifest["database"], readonly=True)) as db:
            integrity(db)
            if sql_signature(db) != manifest["sourceSQL"]:
                raise PreparationError("restored SQLite contents mismatch")
        inject(failure, "restore-verify")
        os.replace(staging, destination)
        return destination
    except BaseException:
        shutil.rmtree(staging)
        destination.rmdir()
        raise


def sql_value(value):
    return {"blob": base64.b64encode(value).decode()} if isinstance(value, bytes) else value


def legacy_snapshot(row, root):
    path = row.get("asset_path")
    blob = None
    if path is not None:
        if not isinstance(path, str):
            raise PreparationError("legacy image path must be a string")
        relative = Path(path)
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise PreparationError("unsafe legacy image path")
        asset = root / "assets" / relative
        asset_root = root / "assets"
        if asset.resolve() != asset or asset_root not in asset.parents or not asset.is_file():
            raise PreparationError("legacy image is missing or outside assets")
        blob = {"path": path, "digest": digest(asset), "byteCount": asset.stat().st_size}
    elif row.get("kind") == "image":
        raise PreparationError("legacy image has no asset")
    tags = (row.get("tags") or "").split()
    return {"legacyRow": row, "blob": blob,
            "manualTags": tags if row.get("tags_version") == -1 else [],
            "generatedTags": [] if row.get("tags_version") == -1 else tags}


def backfill_legacy(root, name="capd.sqlite", failure=None):
    """Adds sidecars on an asset-quiesced synthetic copy, never enqueues."""
    return _backfill_legacy(fixture(root), name, failure)


def _backfill_legacy(root, name="capd.sqlite", failure=None):
    """Shared transformation; callers must establish an authorized isolated copy."""
    name = database_name(name)
    with contextlib.closing(connect(root / name)) as db:
        db.execute("BEGIN IMMEDIATE")
        try:
            assets_before = asset_inventory(root, name)
            db.execute("CREATE TABLE IF NOT EXISTS sync_capture_ids (local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE)")
            db.execute("CREATE TABLE IF NOT EXISTS sync_legacy_snapshot (local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)")
            cursor = db.execute("SELECT * FROM captures ORDER BY id")
            columns = [column[0] for column in cursor.description]
            for values in cursor.fetchall():
                row = dict(zip(columns, map(sql_value, values)))
                local_id = row["id"]
                if not isinstance(local_id, int):
                    raise PreparationError("legacy local ID must be an integer")
                identity = db.execute("SELECT global_id FROM sync_capture_ids WHERE local_id = ?", (local_id,)).fetchone()
                global_id = identity[0] if identity else str(uuid.uuid4()).upper()
                uuid.UUID(global_id)
                payload = encode(legacy_snapshot(row, root))
                existing = db.execute("SELECT global_id, payload FROM sync_legacy_snapshot WHERE local_id = ?", (local_id,)).fetchone()
                if existing and existing != (global_id, payload):
                    raise PreparationError("legacy source changed after preparation")
                db.execute("INSERT OR IGNORE INTO sync_capture_ids VALUES (?, ?)", (local_id, global_id))
                db.execute("INSERT OR IGNORE INTO sync_legacy_snapshot VALUES (?, ?, ?)", (local_id, global_id, payload))
                inject(failure, "backfill-row")
            source_ids = {row[0] for row in db.execute("SELECT id FROM captures")}
            snapshot_ids = {row[0] for row in db.execute("SELECT local_id FROM sync_legacy_snapshot")}
            if source_ids != snapshot_ids:
                raise PreparationError("legacy source deleted rows after preparation")
            if asset_inventory(root, name) != assets_before:
                raise PreparationError("asset tree changed during backfill")
            db.commit()
            return dict(db.execute("SELECT local_id, global_id FROM sync_capture_ids ORDER BY local_id"))
        except BaseException:
            db.rollback()
            raise


def enrollment_plan(root, binding, name="captures.sqlite"):
    """Produces a proposal; no persisted binding, operation or device counter is changed."""
    root = fixture(root)
    name = database_name(name)
    binding = {key: str(uuid.UUID(binding[key])).upper() for key in ("libraryID", "serviceID")}
    with contextlib.closing(connect(root / name, readonly=True)) as db:
        db.execute("BEGIN")
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "sync_meta" not in tables:
            raise PreparationError("client sync state is required")
        db.row_factory = sqlite3.Row
        meta = db.execute("SELECT * FROM sync_meta").fetchall()
        if len(meta) != 1 or meta[0]["role"] != "client":
            raise PreparationError("exactly one client identity is required")
        meta = dict(meta[0])
        uuid.UUID(meta["device"])
        if any(not isinstance(meta[key], int) or meta[key] < 0
               for key in ("sequence", "cursor", "floor", "observed_sequence")):
            raise PreparationError("client counters must be nonnegative integers")
        stored = db.execute("SELECT payload FROM sync_binding").fetchall()
        if stored:
            raise PreparationError("already bound storage is outside unbound migration preparation")
        pending = list(db.execute("SELECT sequence, id, payload FROM sync_outbox ORDER BY sequence"))
        previous = 0
        for row in pending:
            operation = json.loads(row["payload"])
            if (row["sequence"] <= previous or row["sequence"] > meta["sequence"]
                    or operation["sequence"] != row["sequence"]
                    or operation["id"] != row["id"] or operation["deviceID"] != meta["device"]):
                raise PreparationError("pending operation identity or sequence mismatch")
            previous = row["sequence"]
        sequences = [row["sequence"] for row in pending]
        replay = len(sequences) == meta["sequence"] and all(value == index for index, value in enumerate(sequences, 1))
        counts = {table: db.execute('SELECT COUNT(*) FROM "' + table + '"').fetchone()[0]
                  for table in sorted(tables) if table.startswith("sync_") or table == "mobile_captures"}
        return {"protocol": "offline-authority-import-proposal-v1", "binding": binding,
                "deviceState": meta, "counts": counts,
                "pending": [{"sequence": row["sequence"], "id": row["id"],
                             "payloadBase64": base64.b64encode(row["payload"]).decode()} for row in pending],
                "completeSequenceReplayCandidate": replay,
                "activation": "blocked",
                "reason": "requires verified authority history or an approved epoch/import protocol; never seed a device sequence from client claims"}


def prepare_enrollment(source, destination, binding, name="captures.sqlite", failure=None):
    manifest = backup(source, destination, name, failure)
    # Planning only reads the verified snapshot, so app/share changes cannot alter the proposal.
    plan = enrollment_plan(Path(destination) / "payload", binding, name)
    return {"backup": manifest, "enrollment": plan}


def shared_date(value):
    if not isinstance(value, str):
        raise PreparationError("legacy dates must be SQLite date strings")
    date = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if date.tzinfo is None:
        date = date.replace(tzinfo=datetime.timezone.utc)
    epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
    return (date - epoch).total_seconds()


def imported_capture(identity, payload, import_id):
    row = payload["legacyRow"]
    seen_count = row["seen_count"]
    rating = row.get("rating", 3)
    if row["kind"] not in ("link", "text", "image") or not isinstance(seen_count, int) or seen_count < 1 or rating not in range(1, 6):
        raise PreparationError("invalid legacy capture metadata")
    source = {"kind": row["kind"]}
    for shared, legacy in (("contentHash", "content_hash"), ("url", "url"), ("host", "host"),
                           ("title", "title"), ("selection", "selection")):
        if row.get(legacy) is not None:
            source[shared] = row[legacy]
    blob = payload["blob"]
    if blob:
        if blob["byteCount"] > 8_388_608:
            raise PreparationError("image exceeds the shared blob limit")
        source["blob"] = {key: blob[key] for key in ("digest", "byteCount")}
        if row["kind"] == "image":
            if source.get("contentHash") not in (None, blob["digest"]):
                raise PreparationError("image fingerprint differs from verified bytes")
            source["contentHash"] = blob["digest"]
    elif row["kind"] == "image":
        raise PreparationError("image needs verified bytes")
    generated = {"tags": payload["generatedTags"]}
    for shared, legacy in (("body", "body"), ("ocrText", "ocr_text")):
        if row.get(legacy) is not None:
            generated[shared] = row[legacy]
    if row.get("body") is not None:
        generated["bodyIsThin"] = row.get("body_status") == "thin" or row.get("enrichment_state") == "thin"
    record = {"id": str(uuid.UUID(identity)).upper(), "source": source,
              "createdAt": shared_date(row["created_at"]), "revision": 1, "deleted": False,
              "seenCount": seen_count, "noteRevision": 1,
              "noteOperationID": str(uuid.uuid5(import_id, identity + ":note")).upper(),
              "noteConflicts": [], "rating": rating, "manualTags": payload["manualTags"],
              "generated": generated}
    metadata = {}
    for shared, legacy in (("updatedAt", "updated_at"), ("lastSeenAt", "last_seen_at"),
                           ("reminderAt", "reminder_at")):
        if row.get(legacy) is not None:
            metadata[shared] = shared_date(row[legacy])
    if row.get("source_app_bundle_id") is not None:
        metadata["sourceAppBundleID"] = row["source_app_bundle_id"]
    record["metadata"] = metadata
    if row.get("note") is not None:
        record["note"] = row["note"]
    # ASCII JSON bounds Swift string encoding after accounting for its escaped slashes.
    # This deliberately refuses a small margin of otherwise admissible shared records.
    if len(encode(record).replace(b"/", b"\\/")) > MAXIMUM_IMPORTED_CAPTURE_BYTES:
        raise PreparationError("capture exceeds the shared response budget")
    return record


def import_initial_mac(archive, authority, binding, import_id, authority_database="server.sqlite", failure=None,
                       authority_assets="assets"):
    """Imports a synthetic Mac snapshot as a compacted authority baseline, offline only."""
    archive = Path(archive).absolute()
    manifest = verify(archive)
    authority = fixture(authority)
    return _import_initial_mac(archive, manifest, authority, binding, import_id, authority_database,
                               failure, authority_assets, verify)


def _import_initial_mac(archive, manifest, authority, binding, import_id, authority_database,
                        failure, authority_assets, verify_archive):
    """Shared transformation; entry points validate source provenance and destination ownership."""
    separate(archive, authority)
    authority_database = database_name(authority_database)
    authority_assets = database_name(authority_assets, "authority blob directory")
    import_id = uuid.UUID(import_id)
    binding = {key: str(uuid.UUID(binding[key])).upper() for key in ("libraryID", "serviceID")}
    owner = authority / authority_assets / "library-owner"
    if json.loads(owner.read_bytes()) != binding:
        raise PreparationError("authority asset ownership mismatch")
    fingerprint = hashlib.sha256(encode(manifest)).hexdigest()
    source = archive / "payload"
    with contextlib.closing(connect(source / manifest["database"], readonly=True)) as legacy:
        snapshots = legacy.execute("SELECT local_id,global_id,payload FROM sync_legacy_snapshot ORDER BY local_id").fetchall()
        identities = dict(legacy.execute("SELECT local_id,global_id FROM sync_capture_ids"))
        capture_ids = {row[0] for row in legacy.execute("SELECT id FROM captures")}
        if not snapshots or {row[0] for row in snapshots} != capture_ids:
            raise PreparationError("a complete nonempty legacy backfill is required")
        records = []
        legacy.row_factory = sqlite3.Row
        for local_id, identity, payload in snapshots:
            if identities.get(local_id) != identity:
                raise PreparationError("legacy identity mismatch")
            decoded = json.loads(payload)
            current = legacy.execute("SELECT * FROM captures WHERE id=?", (local_id,)).fetchone()
            row = {key: sql_value(current[key]) for key in current.keys()}
            if decoded != legacy_snapshot(row, source):
                raise PreparationError("legacy backfill differs from archived source")
            record = imported_capture(identity, decoded, import_id)
            records.append((local_id, identity, payload, decoded, record))
        hashes = [row[4]["source"].get("contentHash") for row in records if row[4]["source"].get("contentHash") is not None]
        if len(set(hashes)) != len(hashes):
            raise PreparationError("duplicate legacy content fingerprints require reconciliation")
    created = []
    with contextlib.closing(connect(authority / authority_database)) as db:
        db.execute("BEGIN IMMEDIATE")
        try:
            stored = db.execute("SELECT payload FROM sync_binding WHERE id=1").fetchone()
            if stored is None or json.loads(stored[0]) != binding:
                raise PreparationError("authority database binding mismatch")
            meta = db.execute("SELECT role,device,sequence,cursor,floor,observed_sequence FROM sync_meta WHERE id=1").fetchone()
            if meta is None or meta[0] != "server" or meta[1] is not None:
                raise PreparationError("an existing server authority is required")
            db.execute("CREATE TABLE IF NOT EXISTS sync_initial_import (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, count INTEGER NOT NULL)")
            prior = db.execute("SELECT id,fingerprint,count FROM sync_initial_import").fetchall()
            if prior:
                if prior != [(str(import_id).upper(), fingerprint, len(records))]:
                    raise PreparationError("import identity or snapshot changed")
                db.rollback()
                return {"importID": str(import_id).upper(), "count": len(records), "replayed": True}
            if meta[2:] != (0, 0, 0, 0):
                raise PreparationError("initial import requires a pristine authority")
            for table in ("sync_records", "sync_aliases", "sync_receipts", "sync_devices", "sync_feed",
                          "sync_outbox", "sync_visible", "sync_rejections", "sync_observed"):
                if db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]:
                    raise PreparationError("initial import requires empty authority history")
            db.execute("CREATE TABLE sync_imported_legacy (local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)")
            for local_id, identity, payload, decoded, record in records:
                blob = decoded["blob"]
                if blob:
                    asset = source / "assets" / blob["path"]
                    if asset.stat().st_size != blob["byteCount"] or digest(asset) != blob["digest"]:
                        raise PreparationError("legacy image differs from backfill")
                    published = authority / authority_assets / blob["digest"]
                    if published.exists():
                        if digest(published) != blob["digest"] or published.stat().st_size != blob["byteCount"]:
                            raise PreparationError("existing authority blob is corrupt")
                    else:
                        with published.open("xb") as stream:
                            created.append(published)
                            with asset.open("rb") as input_stream:
                                shutil.copyfileobj(input_stream, stream)
                    if digest(published) != blob["digest"] or published.stat().st_size != blob["byteCount"]:
                        raise PreparationError("copied authority image failed verification")
                    inject(failure, "import-asset")
                source_identity = record["source"]
                content_hash = source_identity.get("contentHash")
                identity_blob = source_identity.get("blob") if source_identity["kind"] == "image" else None
                db.execute("""INSERT INTO sync_records
                    (id,payload,source_kind,content_hash,blob_digest,blob_byte_count)
                    VALUES (?,?,?,?,?,?)""",
                    (record["id"], encode(record), source_identity["kind"],
                     unicodedata.normalize("NFC", content_hash) if content_hash is not None else None,
                     identity_blob["digest"] if identity_blob else None,
                     identity_blob["byteCount"] if identity_blob else None))
                db.execute("INSERT INTO sync_imported_legacy VALUES (?,?,?)", (local_id, identity, payload))
                inject(failure, "import-row")
            # An expired cursor selects the existing full-baseline recovery path; no device history is invented.
            db.execute("UPDATE sync_meta SET cursor=1,floor=1 WHERE id=1")
            db.execute("INSERT INTO sync_initial_import VALUES (?,?,?)", (str(import_id).upper(), fingerprint, len(records)))
            verify_archive(archive)
            integrity(db)
            inject(failure, "import-commit")
            db.commit()
            return {"importID": str(import_id).upper(), "count": len(records), "replayed": False}
        except BaseException:
            db.rollback()
            for path in created:
                path.unlink()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["backup", "verify", "restore", "backfill", "prepare-enrollment", "import-initial-mac"])
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--database")
    parser.add_argument("--library-id")
    parser.add_argument("--service-id")
    parser.add_argument("--import-id")
    parser.add_argument("--authority-database", default="server.sqlite")
    parser.add_argument("--authority-assets", default="assets")
    args = parser.parse_args()
    if args.action in ("backup", "restore", "prepare-enrollment", "import-initial-mac") and args.destination is None:
        parser.error("--destination is required")
    if args.action in ("prepare-enrollment", "import-initial-mac") and (not args.library_id or not args.service_id):
        parser.error("--library-id and --service-id are required")
    if args.action == "import-initial-mac" and not args.import_id:
        parser.error("--import-id is required")
    database = args.database
    if database is None:
        database = "capd.sqlite" if args.action == "backfill" else "captures.sqlite"
    try:
        if args.action == "backup":
            result = backup(args.source, args.destination, database)
        elif args.action == "verify":
            result = verify(args.source)
        elif args.action == "restore":
            result = str(restore(args.source, args.destination))
        elif args.action == "backfill":
            result = backfill_legacy(args.source, database)
        elif args.action == "prepare-enrollment":
            result = prepare_enrollment(args.source, args.destination,
                                        {"libraryID": args.library_id, "serviceID": args.service_id}, database)
        else:
            result = import_initial_mac(args.source, args.destination,
                                        {"libraryID": args.library_id, "serviceID": args.service_id},
                                        args.import_id, args.authority_database,
                                        authority_assets=args.authority_assets)
        print(json.dumps(result, sort_keys=True, indent=2))
    except (PreparationError, OSError, sqlite3.Error, ValueError, KeyError) as error:
        parser.exit(1, f"Preparation refused: {error}\n")


if __name__ == "__main__":
    main()
