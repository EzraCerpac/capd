#!/usr/bin/env python3
"""Read-only acquisition and copy-only preparation of an explicitly authorized Mac library."""

import contextlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import uuid

import synthetic_library_migration as migration

RAW_FORMAT = "capd-readonly-mac-snapshot-v1"
PREPARED_FORMAT = "capd-mac-import-copy-v1"
COPY_MARKER = ".capd-authorized-mac-copy.json"
DATABASE = "capd.sqlite"


def canonical(path):
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_dir():
        raise migration.PreparationError("an existing canonical directory is required")
    return path


def source_files(root):
    files = {}
    for suffix in ("", "-wal", "-journal"):
        path = root / (DATABASE + suffix)
        if path.exists() or path.is_symlink():
            if path.is_symlink() or not path.is_file():
                raise migration.PreparationError("database files must be regular files")
            files[path.name] = migration.digest(path)
    if DATABASE not in files:
        raise migration.PreparationError("source database is missing")
    assets = root / "assets"
    if assets.is_symlink() or not assets.is_dir():
        raise migration.PreparationError("source assets must be a regular directory")
    files["assets"] = None
    files.update({"assets/" + key: value for key, value in migration.inventory(assets).items()})
    return files


def copy_files(source, destination, files):
    for relative, checksum in sorted(files.items()):
        target = destination / relative
        if checksum is None:
            target.mkdir(parents=True, exist_ok=True, mode=0o700)
        else:
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with (source / relative).open("rb") as reader, target.open("xb") as writer:
                shutil.copyfileobj(reader, writer)
            target.chmod(0o600)
            if migration.digest(target) != checksum:
                raise migration.PreparationError("copied file differs from source snapshot")


def capture_quiesced(source, destination, failure=None):
    """Caller pauses every database and asset writer; source files are opened read-only only."""
    source = canonical(source)
    destination = migration.separate(source, destination)
    if destination.exists():
        raise migration.PreparationError("snapshot destination must be new")
    if (source / migration.MARKER).exists() or (source / COPY_MARKER).exists():
        raise migration.PreparationError("live acquisition does not accept fixture or prepared roots")
    before = source_files(source)
    destination.mkdir(mode=0o700)
    try:
        payload = destination / "payload"
        payload.mkdir(mode=0o700)
        copy_files(source, payload, before)
        migration.inject(failure, "copy")
        if source_files(source) != before or migration.inventory(payload) != before:
            raise migration.PreparationError("source changed during snapshot")
        manifest = {"format": RAW_FORMAT, "database": DATABASE,
                    "snapshotID": str(uuid.uuid4()).upper(), "sourceRoot": str(source),
                    "files": before}
        (destination / "manifest.json").write_bytes(migration.encode(manifest))
        (destination / "manifest.json").chmod(0o600)
        verify_raw(destination)
        return manifest
    except BaseException:
        shutil.rmtree(destination)
        raise


def verify_raw(archive):
    archive = canonical(archive)
    manifest = json.loads((archive / "manifest.json").read_bytes())
    if manifest.get("format") != RAW_FORMAT or manifest.get("database") != DATABASE:
        raise migration.PreparationError("an approved Mac snapshot format is required")
    uuid.UUID(manifest["snapshotID"])
    payload = canonical(archive / "payload")
    if migration.inventory(payload) != manifest["files"]:
        raise migration.PreparationError("raw snapshot differs from its archive")
    return manifest


def restore_copy(archive, destination):
    archive = canonical(archive)
    manifest = verify_raw(archive)
    destination = migration.separate(archive, destination)
    source = Path(manifest["sourceRoot"])
    migration.separate(source, destination)
    if destination.exists():
        raise migration.PreparationError("working copy destination must be new")
    destination.mkdir(mode=0o700)
    try:
        copy_files(archive / "payload", destination, manifest["files"])
        # WAL recovery and backup touch this disposable copy only, never the archive or live root.
        normalized = destination / "normalized.sqlite"
        with contextlib.closing(migration.connect(destination / DATABASE, readonly=True)) as reader:
            migration.integrity(reader)
            signature = migration.sql_signature(reader)
            with contextlib.closing(sqlite3.connect(normalized)) as target:
                reader.backup(target)
                target.execute("PRAGMA journal_mode=DELETE")
                migration.integrity(target)
                if migration.sql_signature(target) != signature:
                    raise migration.PreparationError("normalized database differs from snapshot")
        for suffix in ("-wal", "-shm", "-journal"):
            (destination / (DATABASE + suffix)).unlink(missing_ok=True)
        os.replace(normalized, destination / DATABASE)
        (destination / DATABASE).chmod(0o600)
        descriptor = {"format": PREPARED_FORMAT, "snapshotID": manifest["snapshotID"],
                      "sourceRoot": manifest["sourceRoot"], "copyRoot": str(destination),
                      "sourceSQL": signature, "sourceFiles": manifest["files"]}
        (destination / COPY_MARKER).write_bytes(migration.encode(descriptor))
        (destination / COPY_MARKER).chmod(0o600)
        verify_raw(archive)
        return descriptor
    except BaseException:
        shutil.rmtree(destination)
        raise


def working_copy(root):
    root = canonical(root)
    descriptor = json.loads((root / COPY_MARKER).read_bytes())
    if descriptor.get("format") != PREPARED_FORMAT or descriptor.get("copyRoot") != str(root):
        raise migration.PreparationError("an explicit authorized working copy is required")
    uuid.UUID(descriptor["snapshotID"])
    migration.separate(Path(descriptor["sourceRoot"]), root)
    if (root / migration.MARKER).exists():
        raise migration.PreparationError("real copies must not be labeled synthetic")
    migration.inventory(root)
    return root, descriptor


def require_unused_sync(db):
    error = "copied source must be unbound and unused for sync"
    preparatory = {"sync_capture_ids", "sync_legacy_snapshot"}
    tables = {name.lower(): name for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    try:
        for name, original in tables.items():
            if not name.startswith("sync_") or name in preparatory:
                continue
            quoted = '"' + original.replace('"', '""') + '"'
            if name != "sync_meta":
                if db.execute(f"SELECT 1 FROM {quoted} LIMIT 1").fetchone():
                    raise migration.PreparationError(error)
                continue
            rows = db.execute(f"SELECT id, role, device, sequence, cursor, floor, observed_sequence FROM {quoted}").fetchmany(2)
            if not rows:
                continue
            if len(rows) != 1:
                raise migration.PreparationError(error)
            identifier, role, device, *counters = rows[0]
            if type(identifier) is not int or identifier != 1 or role != "client" or not isinstance(device, str):
                raise migration.PreparationError(error)
            if str(uuid.UUID(device)).lower() != device.lower():
                raise migration.PreparationError(error)
            if any(type(value) is not int or value != 0 for value in counters):
                raise migration.PreparationError(error)
        if "sqlite_sequence" in tables:
            for name, sequence in db.execute("SELECT name, seq FROM sqlite_sequence"):
                if name.lower().startswith("sync_") and name.lower() not in preparatory and sequence != 0:
                    raise migration.PreparationError(error)
    except (sqlite3.Error, ValueError, AttributeError) as exc:
        raise migration.PreparationError(error) from exc


def backfill(root):
    root, _ = working_copy(root)
    with contextlib.closing(migration.connect(root / DATABASE, readonly=True)) as db:
        require_unused_sync(db)
    return migration._backfill_legacy(root, DATABASE)


def archive_prepared(root, destination):
    root, descriptor = working_copy(root)
    destination = migration.separate(root, destination)
    if destination.exists():
        raise migration.PreparationError("prepared archive destination must be new")
    destination.mkdir(mode=0o700)
    try:
        payload = destination / "payload"
        payload.mkdir(mode=0o700)
        with contextlib.closing(migration.connect(root / DATABASE, readonly=True)) as reader:
            migration.integrity(reader)
            require_unused_sync(reader)
            signature = migration.sql_signature(reader)
            with contextlib.closing(sqlite3.connect(payload / DATABASE)) as target:
                reader.backup(target)
                target.execute("PRAGMA journal_mode=DELETE")
                migration.integrity(target)
        files = {k: v for k, v in source_files(root).items() if k == "assets" or k.startswith("assets/")}
        copy_files(root, payload, files)
        (payload / DATABASE).chmod(0o600)
        manifest = {"format": PREPARED_FORMAT, "database": DATABASE,
                    "snapshotID": descriptor["snapshotID"], "sourceRoot": descriptor["sourceRoot"],
                    "sourceSQL": signature, "files": migration.inventory(payload)}
        (destination / "manifest.json").write_bytes(migration.encode(manifest))
        (destination / "manifest.json").chmod(0o600)
        verify_prepared(destination)
        return manifest
    except BaseException:
        shutil.rmtree(destination)
        raise


def verify_prepared(archive):
    archive = canonical(archive)
    manifest = json.loads((archive / "manifest.json").read_bytes())
    if manifest.get("format") != PREPARED_FORMAT or manifest.get("database") != DATABASE:
        raise migration.PreparationError("a verified real-source copy archive is required")
    uuid.UUID(manifest["snapshotID"])
    payload = canonical(archive / "payload")
    if migration.inventory(payload) != manifest["files"] or (payload / migration.MARKER).exists():
        raise migration.PreparationError("prepared archive differs from its inventory")
    with contextlib.closing(migration.connect(payload / DATABASE, readonly=True)) as db:
        migration.integrity(db)
        require_unused_sync(db)
        if migration.sql_signature(db) != manifest["sourceSQL"]:
            raise migration.PreparationError("prepared archive database differs")
    return manifest


def import_copy(archive, authority, binding, import_id):
    archive = canonical(archive)
    manifest = verify_prepared(archive)
    authority = canonical(authority)
    owner = json.loads((authority / COPY_MARKER).read_bytes())
    if owner != {"format": PREPARED_FORMAT, "snapshotID": manifest["snapshotID"],
                 "authorityRoot": str(authority), "binding": binding}:
        raise migration.PreparationError("authority is not owned by this copy-only dry run")
    migration.separate(Path(manifest["sourceRoot"]), authority)
    return migration._import_initial_mac(archive, manifest, authority, binding, import_id,
                                          "authority.sqlite", None, "blobs", verify_prepared)
