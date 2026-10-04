# Offline snapshot administration

`capd-sync-admin` previews and imports copied phone content into an existing, bound
authority on its host. It has no HTTP listener, MCP tool, grant handling, enrollment,
or authority creation. It uses the existing `ContentSnapshotImport` contract.

Transfer a quiesced copy's manifest as JSON and its referenced assets as files named
by their lowercase SHA-256 digest in a separate directory. Preserve the original
phone database, WAL, receipts, device identity and exact outbox in its separate
backup. This command does not modify or activate the phone. The asset directory is
required even for a manifest without images.

The host must be stopped: both commands acquire its exclusive `.server.lock` for
the entire operation. Explicit service and library UUIDs must match `service.json`,
the existing authority's SQLite server role and binding, and its blob ownership
marker. Missing, incomplete or differently scoped storage is refused before opening
the write-capable server API. Only the UUID-derived library directory is opened.

```sh
swift build --package-path Packages/CapdSyncAdmin -c release
capd-sync-admin preview \
  --data-dir /path/to/copied-authority \
  --service-id SERVICE_UUID --library-id LIBRARY_UUID \
  --snapshot /path/to/transfer/snapshot.json \
  --assets /path/to/transfer/assets \
  --review /path/to/private-review.json
```

Preview creates a new file with mode `0600` and prints `review-sha256 HASH`. It
refuses to overwrite an existing path. `SnapshotReview` version 1 contains the
canonical authority directory, SHA-256 of the exact manifest bytes, sorted unique
`BlobReference` assets and the complete `ContentSnapshotImportPreview`. That preview
includes original source and competing authority values, canonical capture IDs,
dispositions, differing fields, counts, cursor, floor and the feed rows to expire.
Every count is a maximum-known lower bound, never an exact aggregate. Review the
actual competing values, tombstones, conflicts and feed expiration before choosing
an import. The hash identifies those exact reviewed bytes; computing a hash is not
approval by itself.

```sh
umask 077
capd-sync-admin import \
  --data-dir /path/to/copied-authority \
  --service-id SERVICE_UUID --library-id LIBRARY_UUID \
  --snapshot /path/to/transfer/snapshot.json \
  --assets /path/to/transfer/assets \
  --review /path/to/private-review.json \
  --reviewed-sha256 EXPLICITLY_REVIEWED_HASH > /path/to/new-import-receipt.json
```

Import requires the explicit review hash, rereads the bounded manifest and every
asset, verifies their sizes and hashes, and recomputes the preview before publishing
assets. Changed manifest bytes (including whitespace), reviewed artifacts, assets,
scope or authority state require another review. An already imported identical
snapshot is an idempotent receipt recovery, including after reopening the host.
The core API performs its own preview comparison inside the database transaction.

The command returns the existing `ContentSnapshotImportReceipt` as JSON on stdout.
Its `digest` is the shared contract's digest of the decoded manifest encoded with
sorted keys and default JSON date encoding; it is distinct from the raw-file hash
in the review. Receipt fields include snapshot ID, target binding, source device ID,
authority cursor, count policy and per-item source/canonical mappings, new import
IDs and note provenance. It acknowledges no original phone operation. Authority
device sequences and ordinary receipts remain unchanged; expired feed rows are
archived by the shared import API.

The activation coordinator consumes a receipt obtained through this explicitly
reviewed administrative handoff and verifies its snapshot ID, manifest digest,
binding, source device ID, count policy and complete item mappings against its
retained manifest and reviewed preview. Arbitrary receipt JSON is not proof of
authority origin, and a hash supplied inside that same JSON does not establish
trust. Approval or a separately pinned receipt hash must come from the coordinated
host-side result. Activation and its authenticated authority verification are
separate from this tool.

Manifest reads are limited to 16 MiB and review artifacts to 64 MiB. Each asset is
limited to 8 MiB, with at most 4096 distinct assets and 1 GiB of total asset bytes.
Only required assets are read, one at a time. Assets are digest-derived paths;
symlink/nonregular/hardlinked leaf files, wrong hashes/sizes and corrupt existing
authority assets are refused. The host filesystem and transfer directory must be
quiescent and controlled by the operator; this is not a sandbox for hostile local
writers replacing path ancestors while a command runs.

Verified assets are published atomically and without replacing existing files.
The file and its parent directory are synced before SQLite can commit a reference.
Database failure removes only assets this invocation newly published. File staging
is outside SQLite: interruption can leave verified unreferenced assets or private
`.capd-admin-*.tmp` files. Keep the original backup and review. Repeating the exact
reviewed import safely reuses verified assets and recovers a committed receipt;
orphan cleanup is an independent administrative action. Underlying storage errors
are not printed because they may contain private library data.

`swift test --package-path Packages/CapdSyncAdmin` runs synthetic host and CLI tests
covering scope/ownership/locking refusal, stale and altered reviews, asset integrity,
private exclusive artifact publication, rollback and exact receipt recovery. An
old unbound phone fixture has accepted sequence 1 and queued sequences 2 and 3;
export/import preserve its SQLite/WAL bytes and exact queued operations.
