# Synthetic offline sync prototype

The prototype exercises a complete local library and a separate authority using
synthetic records and small files. It lives in `Packages/CapdSync`, a standalone
Swift package. The Mac app does not enable it. Opening `Store` still runs only
migrations 001–005, and capture, annotation, deletion and enrichment retain their
existing local behavior.

The package depends on GRDB 7.11.1 and swift-crypto 4.0.0. GRDB remains the storage
engine. swift-crypto supplies SHA-256 without importing Mac-only capture or
inference frameworks. The portable package imports Foundation, GRDB and Crypto;
it does not import CapdKit, AppKit, Vision or FoundationModels. It declares macOS
13 and iOS 16 support. The shared mobile package and app also build for the
installed iOS simulator SDK. Linux execution remains unverified.

## Record and transport boundary

`SharedCapture` has an immutable UUID and immutable captured source. A local
integer key and a content fingerprint serve different purposes. Fingerprint
matches resolve to the first accepted capture UUID through an alias; operation
IDs and proposed UUIDs are not rewritten. Captures with no fingerprint remain
independent.

Manual notes, rating and tags are separate from generated body, OCR and tags.
The protocol contains neither enrichment leases, retry counters, process state
nor FTS internals. Capture source is intentionally small: kind, fingerprint,
URL, host, title, selection and optional blob reference. Reminder scheduling,
source-app details, taxonomy versions and other Mac-specific fields are outside
this prototype's shared model.

`SyncTransport` exposes apply, paged changes, baseline, upload and download.
Values are Codable and Sendable. `LoopbackTransport` round-trips the domain
values through JSON in process. `ReferenceTransport` additionally supports
synthetic process/simulator tests using bounded frames to 127.0.0.1 only.
`capd-sync-reference` binds fresh ephemeral loopback ports for the authority and
portable Mac fixture; it has explicit failure-injection controls and is
**not deployable**. A separate authenticated, library-scoped HTTP boundary is
prepared in `production-sync.md`; no remote service or production credentials are
configured. The iPhone automatic scheduler is described in `automatic-sync.md`.
A future native client can implement this transport without importing Mac
capture code. A server-hosted read-only MCP can consume `AcceptedCaptureReader`;
this read interface exposes accepted non-deleted records and no mutation API.
That reader does not itself authorize access.

## Local durability and reconciliation

Each device has a persisted UUID and sequence counter. `SyncClient.enqueue`
commits the operation, sequence, visible row and optional source-row projection
in one GRDB transaction. The operation contains a UUID, device ID, sequence,
capture UUID and observed base revision. Reopening with another device UUID is
an error. When no UUID is supplied, the shared database allocates it atomically;
app and extension writers reuse it. An editor can supply its opening revision
instead of silently adopting a newer shadow revision at save time.

The client stores accepted shadow records separately from an ordered durable
outbox. It reconstructs the visible library by overlaying unsent operations on
the shadow. Pull commits shadow records, visible projections and its cursor
atomically, and never enqueues received changes. An acknowledgement removes
only the exact first pending operation. Rejected work remains inspectable with
its operation and receipt, including notes rejected after deletion.

A feed change identifies its originating operation. An own-device echo suppresses
that pending overlay without deleting the retryable operation. Baselines include
device sequence high-water marks for the same purpose after cursor expiry.
This avoids double-counting a committed recapture whose acknowledgement was lost.
The client still retries the original operation to recover its receipt.

## Authority and conflicts

The server serializes writes in SQLite. One transaction commits the mutation,
operation receipt, device sequence and monotonic change-feed entry. Replaying an
identical operation returns its persisted receipt. Reusing its ID for different
content fails. A sequence gap fails without consuming the operation. A transient
blob failure also leaves the operation available for retry.

A new fingerprint match represents one recapture and increments `seenCount`
once. A dedicated recapture operation does the same. Replaying either operation
does not increment it again. Deduplication receipts identify the canonical UUID.
The authority queries an index of source kind, normalized content hash and image
blob identity, including tombstones and choosing the first matching UUID. Every
record save updates these fields. Shared database preparation backfills older
payload-only databases one record at a time inside the migration transaction.

Feed pages respect both the requested record count and a 16 MiB serialized-byte
budget. The HTTP budget includes the principal and capability envelope. Paging
checks stored payload lengths before reading each change and stops at the last
included cursor. A single oversized change returns a resource-limit error without
advancing past it; clients retain their existing adaptive page retry behavior.
HTTP baseline reads count device-sequence and capture bytes incrementally under
the same envelope budget. An oversized whole baseline or requested baseline page
returns a resource-limit error; a partial page could falsely signal end of data.
Paged clients reduce the requested count and retry at the same position. Every
baseline carries required `totalCaptureCount`, including tombstones, computed in
the same read transaction as its cursor and records. Both HTTP clients pin the
cursor, device sequences and total across pages, require each page to contain
`min(limit, totalCaptureCount - capturesAlreadyReceived)` records in UUID order,
and finish only after receiving the advertised total. A zero-limit request
returns an explicit summary with the full total. Missing, negative or inconsistent
totals are invalid responses; short pages do not independently prove completion.
Complete native baselines also require the total to match their records before
blob downloads or shadow replacement. The in-process baseline APIs retain their
full-library and count-bounded behavior.

Clients require feed cursors to be contiguous and each capture revision to equal
its change cursor before downloading blobs or committing the page. Receipt checks
require each outcome's capture presence, canonical identity and compatible
mutation before blob caching or durable outbox removal. Duplicate creates can
introduce fingerprint-matching aliases, and saved retry receipts can precede the
current local revision.

A stale note edit creates explicit variants, including a cleared note. Resolving
variants requires their IDs and the revision the resolver observed. A resolution
that has become stale preserves its candidate as another conflict rather than
silently overwriting a concurrent resolution. Pending local note edits remain
visible while a pull refreshes independent fields.

A predecessor link records causality within queued edits. It advances the note
base only to a note established by that predecessor; a rating or tag edit cannot
make an unseen concurrent note appear observed. Independent tag add/remove
operations merge against current manual tags. Rating and generated content use
accepted application order. Concurrent modifications to the same non-note field
are not separately versioned conflicts, and tag add/remove is not a general CRDT.

Delete creates a durable tombstone. Stale edits, recaptures and new UUIDs with
that deleted fingerprint cannot resurrect it. Restore is an explicit operation
at the exact accepted tombstone revision. A predecessor receipt cannot authorize
restoration at a deletion revision the caller has not observed. Tombstones,
receipts, aliases and published assets are retained; only the change feed can be
pruned. Cursor expiry returns a consistent baseline, then replays pending local
work without changing its IDs, bases or order.

## Blob publication

Blob references contain a lowercase SHA-256 digest and byte count. Filenames are
derived from validated digests, never from caller-supplied paths. The prototype
limits each blob to 8 MiB. Uploads stage partial bytes, verify retry offsets and
content, then verify the complete digest before atomic publication. An interrupted
upload can resume after reopening the server. A poisoned complete partial is
removed so a full retry can repair it.

The authority accepts an image capture only after its referenced blob verifies.
The client downloads and verifies referenced assets before committing pulled
records or cursor advancement. A corrupt local cache can be replaced by verified
bytes, with the old path retained until atomic replacement. Local image creates and
tombstone restores verify their assets before queuing. An unavailable
older cache entry preserves its visible record and does not block unrelated offline
edits; reading that asset still reports the missing or invalid blob, and a later pull
of its record rehydrates it from the authority. Published authority assets must
remain under the store's ownership. External file deletion/corruption, disk-full
recovery and power-loss durability across SQLite and filesystem writes are not
proven by these tests. No blob garbage collection runs in the prototype.

## Existing storage and search

`SyncPrototype` in CapdKit is an internal, opt-in fixture adapter. No application
service calls it. Its identity backfill adds a separate `sync_capture_ids` table,
assigns UUIDs to existing local rows and preserves their integer keys and content
fingerprints. Repeating the backfill keeps those UUIDs stable. It does not modify
the existing migration registry or FTS schema.

The adapter maps a visible shared capture into the ordinary `captures` source
row inside the sync transaction. Existing FTS triggers derive the index from that
row. It preserves an existing row's local enrichment state and attempts. The
legacy tags column is a union projection of manual and generated tags; a row with
manual tags remains pinned. The separate sync shadow retains both categories.
A production integration needs a deliberate schema/UI decision for mixed tag
provenance before enabling the adapter. Snapshot conversion is a fixture helper,
not a production whole-library import preserving every historical statistic.

## Checks and limits

The portable tests use unique temporary databases and synthetic assets. They
exercise offline create/edit/delete and reopen; duplicate requests and lost
acknowledgements; own feed echo; fingerprint aliases; interrupted and corrupt blob
transfer; concurrent notes and stale resolution; independent-field note causality;
stale operations after deletion; explicit restoration; cursor expiry with pending
work; transactional projection failures; device identity and sequence gaps; and
paged cursor advancement.

The CapdKit compatibility tests backfill only disposable databases and verify
unchanged legacy migration/FTS columns, local keys, URL substring search, note/tag
and body/OCR FTS, preserved local enrichment state and local-only behavior.
Existing focused storage, dedupe, annotation and FTS tests cover likely regressions.

Run the portable suite with:

```sh
swift test --package-path Packages/CapdSync --jobs 6
```

Run the focused compatibility checks from the repository root with a disposable
`CAPD_DIR`:

```sh
swift test --jobs 6 --filter 'SyncCompatibilityTests|StoreTests|FTSEscapingMatrixTests|DedupeTests|AnnotateTests'
```

The prototype assumes one sync coordinator per client library and one authority
process per server blob directory. SQLite handles concurrent database writes;
file transfer staging is locked within one BlobStore instance. It does not claim
multi-process blob staging, bounded total history/storage, production performance,
server restart orchestration or a deployed wire/schema migration policy.
Fingerprint lookup and visible reconstruction scan the synthetic library. Baseline
recovery returns the full library rather than streaming it. These choices keep the
failure protocol inspectable without creating a deployment stack.

The integrated iPhone app and extension use this same outbox through a source-row
projection on their App Group database. The default adapter stays unconfigured;
only explicit DEBUG simulator flags opt into the reference socket transport.
Actual process-flow tests are distinct from the legacy Mac Store fixture tests;
the portable Mac peer does not round-trip the legacy union/pinned tag column.
See `iphone-client.md` for supported mobile actions and fresh-fixture limits.
Custom is the accepted engine direction and the production preparation targets a
self-hosted service. The configured backend remains a non-deployable synthetic
reference. See `production-sync.md` for the prepared authorization/enrollment boundary
and the remaining application activation, retention and deployment work.
