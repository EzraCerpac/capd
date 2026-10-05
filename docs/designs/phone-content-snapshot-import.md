# Explicit phone content snapshot import

This local administrative contract preserves visible content from a copied populated phone library when complete original receipts and operation history are unavailable. It does not reconcile or acknowledge that original history. The phone database, device ID, sequence, accepted state and exact pending BLOBs remain unchanged. Default LocalOnly behavior, the activation gate and the used-unbound-library guard remain intact.

## Export and preview

`MobileStore.contentSnapshotImport(snapshotID:targetBinding:)` and the corresponding `SyncClient` method read the existing `sync_visible` records, including pending overlays and tombstones, without writing the source. They return a version-1 `ContentSnapshotImport` manifest containing the stable caller-supplied snapshot ID, target binding, source device ID, sorted full original records and `maximumKnownLowerBound` count policy. This content manifest is accompanied by the retained original database/outbox archive; it is not a substitute for that history or an enrollment result. Export a verified quiesced copy, not a changing live library.

`SyncServer.previewContentSnapshotImport(_:)` requires the target authority binding and validates record shape, counts, source identities and bounded manifest size. The preview contains each original source record, its matching authority record, the canonical mapping, insert/merge/tombstone disposition, differing fields and proposed count. Differences include source, creation time, deletion, notes/conflict variants, rating, tags, generated content, metadata, counts and extensions. It also reports the current cursor/floor and the number of feed rows the import will archive and expire. Callers can show the actual competing values before deciding whether to import.

No preview claims historically exact counts: `countIsExact` is false. Unique content copies the source's recorded count. A live content match uses `max(authority.seenCount, source.seenCount)`, never addition or a recapture. This is a maximum-known lower bound because the snapshots can overlap in unknown ways. The source and prior authority counts remain in the immutable ledger for later reconciliation. A repeated content snapshot does not inflate the count.

## Administrative import

The frozen methods are:

```swift
SyncServer.previewContentSnapshotImport(
    _ snapshot: ContentSnapshotImport
) throws -> ContentSnapshotImportPreview

SyncServer.importContentSnapshot(
    _ snapshot: ContentSnapshotImport,
    preview: ContentSnapshotImportPreview
) throws -> ContentSnapshotImportReceipt

SyncServer.retainedContentSnapshotImport(
    _ snapshotID: UUID
) throws -> RetainedContentSnapshotImport?

SyncServer.expiredContentSnapshotFeed(
    _ snapshotID: UUID
) throws -> [FeedChange]
```

An intervening authority content/cursor/floor change invalidates the preview. Import validates the preview again inside one writer transaction and verifies all referenced blobs before writing. Missing assets, identity collisions or SQL failures leave records, aliases, metadata, counters, feed and ledger unchanged. Asset staging uses the existing verified blob API separately; the content import itself does not copy or remove external files.

A new unique capture retains its full content, original creation/domain timestamps, source application, recorded count, deletion state and descriptive extensions. It receives the new import revision and freshly allocated note/variant identifiers. The receipt records the original-to-new note identifiers; it does not pretend these are historical device acknowledgements.

A matching fingerprint or existing identity keeps the authority's source, creation/provenance, metadata, generated content and rating. Manual tags are unioned. Different note values become explicit canonical note conflicts under new import variant IDs, while the prior canonical value remains available. Every source value, including competing metadata, generated content, rating, extensions and original conflict identifiers, is retained in `sync_content_snapshot_imports` and returned through the preview/ledger. Equal note values do not add duplicate conflicts. Tombstones are never revived: if either side is deleted, the existing canonical deletion/content/count is retained and the other snapshot stays in the ledger. An existing UUID paired with different content identity is rejected instead of repurposed.

The `ContentSnapshotImportReceipt` is an honest new administrative receipt, separate from `SyncReceipt`. No row is inserted into ordinary `sync_receipts` or `sync_devices`; no source sequence is reset, renumbered, claimed accepted or seeded into the authority. Original operation receipts and device counters remain byte-for-byte unchanged. Repeating the same snapshot ID and identical manifest returns the exact stored import receipt, including after authority reopen. Changed content under that ID is refused.

## Baseline recovery and retained history

The import archives the exact existing feed payloads in `sync_content_snapshot_expired_feed` before expiring them. It advances cursor and floor to one new authority revision. Connected clients below that floor select their existing full-baseline recovery path; no device-authored feed event is fabricated. Original authority receipts/device counters and all archived feed rows remain available. Client pending operations retain their IDs, sequences, predecessors and stored bytes across recovery, and are acknowledged only by a later actual operation receipt.

The ledger retains the original manifest, reviewed competing authority values, new receipts/mappings and expired feed. It supplies inspectable preservation history, not an automatic undo of later accepted work. No HTTP import action, app activation, replacement phone database or live migration coordinator is exposed by this change.

## Synthetic verification

`ContentSnapshotImportTests` covers previews and competing values, original metadata/count preservation, new receipt provenance, idempotent retry/reopen, two same-fingerprint source rows, tombstones, invalid binding/counts/identities/assets, stale previews and SQL-trigger rollback. Bound HTTP client fixtures recover after feed expiration with pending overlays and exact outbox bytes, while original receipts/device rows and archived feed remain intact.

`ContentSnapshotExportTests` uses an actual populated synthetic MobileStore with accepted/generated content and an advanced outbox beginning at sequence 2. Export and import leave its SQLite and WAL bytes, logical rows, FTS results, original device ID and exact queued operations unchanged. New import receipts acknowledge none of those pending operation IDs, and the used-unbound enrollment guard still refuses activation.

The conflicting metadata/count choices are exposed for eventual user review. A live phone export/import, discarding original pending history, changing app storage or enabling enrollment remains outside this contract's authorization.
