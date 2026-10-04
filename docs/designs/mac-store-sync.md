# Opt-in Mac Store outbox

`Store(paths:)` remains local-only. Explicit `syncBinding:` configures the shared
outbox on the same SQLite database as Mac captures. The app, CLI, agent and share
capture defaults do not opt in automatically. This is code preparation exercised
only with synthetic libraries, not a real-library activation or device migration.

## Mutation inventory

| Entry point | Shared work in the local transaction |
| --- | --- |
| `upsertCapture` / `CaptureService.ingest` | Stable UUID allocation plus create; duplicate recapture plus selective note/tag/source/metadata edit |
| `CaptureService.annotate` / `updateNote` | Note edit and original domain update timestamp |
| `updateRating` | Rating edit and update timestamp |
| `scheduleReminder` | Explicit reminder set and update timestamp |
| `claimNextDueReminder` | Explicit reminder clear and update timestamp |
| `deleteCaptures` | Delete with the existing global UUID; mapping survives as a tombstone |
| `completeEnrichment` | Independent body/OCR patch, source-title hole-fill and update timestamp when content changes |
| `completeTagging` | Generated tag patch and update timestamp, preserving manual tags |
| `prepareRetagging` | Generated-tag clear for each affected capture, preserving manual categories |
| `applyTaxonomyRevision` | Per-batch generated-tag revision, preserving manual categories |

Pinboard import, normal app captures, CLI add/import, annotations and agent outcomes
use these Store paths. Taxonomy configuration, retag request flags, pipeline claims,
reclaim/requeue counters, FTS rebuilds and diagnostics stay local. They do not create
shared operations merely for private pipeline state changes. Every SQLite mutation
passes the common persisted-binding guard, so a stale local-only Store cannot write
after another handle enrolls the database. Multiple matching configured Store handles
share the same device and ordered outbox.

## Transaction and projection

`SyncClient.enqueue(in: Database, ...)` participates in the Store write transaction.
The local capture update, UUID mapping, exact operation payload, predecessor link,
sequence allocation, visible projection and FTS trigger effects commit or roll back
together. A recapture and its selective metadata edit may be two operations in that
same transaction. The projection never enqueues; remote pulls and acknowledgements
therefore do not generate feedback operations.

Source kind, URL, content hash, blob and original source application are fixed.
Title/selection patches only fill holes. Body and OCR patches are independent; tag
changes preserve manual/generated categories held in shared state instead of deriving
them from the legacy union column. Domain timestamps are carried verbatim; sync does
not manufacture a delivery timestamp. Unknown descriptive fields remain in shared
records; Store projection reads the fields it displays.

The mapping retains the Mac integer key. Canonical alias projection reuses a local
alias row instead of inserting a competing row with the same content hash. The
original operation UUID and capture UUID remain in the immutable outbox and alias
history. Deletion retains the mapping, and a later capture receives a new integer key.
If its fingerprint aliases an existing tombstone, every matching local projection
is removed, while identity mappings and exact rejected work remain available. A
create does not silently restore a deleted capture; explicit restoration remains a
separate operation.

Image creates verify native nested asset paths and stage content-digest bytes in
`assets/sync`. Queued operations retain these bytes after local deletion and through
orphan sweep, reopen and retry. The sweep always reserves this namespace, including
when an old local-only handle races enrollment. Native unreferenced assets keep their
existing sweep policy. Blob retention is conservative; this code does not implement
sync-blob garbage collection or storage quotas.

## Existing imported Mac library

Arbitrary unbound populated storage cannot opt in. `StoreSyncImportHandoff` is an
explicit path for a quiesced copied Mac library and a matching bound initial-import
authority. It fetches the authority baseline through a bound transport and validates:

- Cursor 1, no authority device history, no deleted or conflicted imported records.
- One-to-one local integer keys and global UUIDs, matching the importer identity map.
- Exact source values, creation time, counts, rating, note, generated/manual tags and
  supported metadata, including original timestamps/reminder/source application.
- Verified local image bytes matching each shared blob reference.

The async initializer takes `AsyncSyncTransport` and a credential provider directly.
It obtains a fresh authenticated baseline through the same cancellable HTTP executor
as ordinary sync, checks the enrolled principal and metadata capability, then validates
the copied Store. It does not require a caller-built baseline adapter or persist the
credential. Authentication, malformed replies, unsupported capabilities and cancellation
fail before a handoff is returned. Constructing a handoff does not bind or mutate the
Store; the explicit Store initializer below performs the transactional attachment.

The initializer rechecks the copied rows, identities and images inside the existing
SyncClient preparation transaction. The normal used-history, binding, role, device
and unbound-blob guards run before the `prepareProjection` seed callback. Baseline,
cursor, identity/projection setup, binding and device identity commit together; failure
rolls back the database and removes only newly staged import blobs. It does not relax
the enrollment guard for a previously used unbound sync database.

The initial local captures and enrichment bookkeeping remain unchanged. Subsequent
ordinary Store mutations enqueue against the accepted revision, and matching-bound
reopen keeps the same identity/outbox. An imported handoff is not a generic merge API:
changed source rows, mismatched binding/device, a noninitial authority, incomplete
mapping or used client history fail closed. Cutover still requires source writer
quiescence and separately approved activation of all app/agent/CLI capture writers.

## Populated phone decision

Synthetic replay tests show that a complete original unsent sequence starting at 1
can reconcile a duplicate create to the Mac canonical capture, preserve predecessor
links and exact pending bytes, and obtain repeat-safe receipts. That is a disposable
reconciliation candidate, not permission to bind a used phone database.

An advanced outbox starting at 9 is rejected by a Mac-seeded authority expecting 1.
An unknown alias can yield a missing receipt and consume its sequence. A missing
predecessor receipt fails, and old cursor/revision epochs cannot be assumed compatible
with cursor 1. Baseline recovery refuses an unverified device high-water that
collides with pending operations without observed acceptance evidence. It preserves
the exact outbox, accepted baseline, visible library and cursor. These cases are tested.

If authoritative original operation receipts, canonical aliases and revision/history
provenance are unavailable, preserve the phone snapshot and exact outbox unchanged
and keep enrollment blocked. Do not seed device counters from client claims, reset
the phone or reinterpret/renumber pending operations. A typed migration/epoch protocol
and validated history merge remain separate shared-API work and require approval.

No real Mac library, physical phone, NAS, credentials or live cutover is involved in
these tests. The next real-library step remains an explicitly approved read-only
snapshot of the identified Mac root with all asset/library writers quiesced, followed
by validation on a separate local copy. Phone inspection and activation need separate
later approval.
