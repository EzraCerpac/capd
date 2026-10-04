# iPhone client and shared outbox

The iPhone app and extension use one App Group SQLite/WAL database. `MobileStore`
opens a GRDB DatabasePool, migrates only its source projection, then injects that
same writer into `SyncClient`. Shared `sync_meta` allocates a device UUID once inside
a transaction and retains its sequence counter across both processes and launches.
No `PendingCapture` type, separate `pendingCaptures` queue, or mobile set-of-IDs ACK
implementation remains.

`save`, annotation edits and deletion enqueue domain mutations. The shared outbox
entry, sequence and visible source projection commit atomically. Accepted shadow
records and unsent overlays determine the visible library. Pull advances source
projection and cursor together. ACK uses the shared exact-oldest-operation path,
including projection and removal in the same transaction. A concurrent extension
save remains queued and cannot be cleared by another operation's receipt.

Mobile rows retain local integer keys separately from immutable capture UUIDs.
Notes, manual tags, generated body/OCR/tags, conflict variants and accepted revision
are projected separately. FTS derives from these source rows; URLs also retain a
literal substring fallback. The shared URL normalizer and SHA-256 helper preserve
Mac fingerprint rules. No FTS internals or enrichment leases/retry state are sent.

An annotation form freezes its opening capture alongside its typed text. Save
compares against those original notes/manual tags, passes the observed revision,
and resolves only explicitly selected conflict IDs from that snapshot. A remote
refresh cannot rebase an older draft or remove a tag the user did not observe.
Source details read an observable model cache so projected changes are rendered.
Delivery is automatic after local changes, foreground/reopen and connectivity return,
with a bounded active pull cadence for remote changes. See `automatic-sync.md` for
scheduler policy, cancellation and presentation boundaries.
Each pull cycle processes at most 100 pages and returns normally with its durable
cursor; later foreground polls continue the feed so queued pushes get a turn.
The coordinator coalesces matching request modes. Pull-only refreshes and
push-capable syncs run separately in sequence, with their own results.
Cancelling a joined caller ends only its wait; the caller that starts the shared
flight owns its cancellation. Scheduler updates carry a lightweight committed
library revision, so status-only updates do not reload capture text. Conflict
counts are cached until that revision changes.

The replaceable adapter provides a `SyncTransport`. The default is unconfigured.
Only a DEBUG simulator launch flag activates `ReferenceTransport`, a bounded framed
TCP connection to 127.0.0.1. The reference executable runs two separate processes:
an authority with its own GRDB database and a portable Mac `SyncClient` with its own
library, connected through that same transport. Its test controls inject socket
closure after commit and temporary connection refusal; these are synthetic network
failures, not a physical-radio or production-network test.

The iOS UI supports capture/share/search, manual annotations/tags, explicit note
resolution and delete. Restore, ratings, enrichment, blob/image creation, taxonomy
management and server/account configuration have no mobile UI here. Their existing
portable protocol coverage does not imply an iOS UI action. Custom is the accepted sync direction; the configured backend remains a synthetic
loopback reference. The separate authenticated boundary described in
`production-sync.md` is prepared but no production adapter or service is activated.

Use fresh disposable libraries. Opening a legacy mobile database with a
`pendingCaptures` table is refused; no real-user migration is implemented or tested.
The existing internal Mac Store fixture adapter still projects mixed tags into its
legacy union/pinned column and its snapshot can promote generated tags to manual.
The actual process flow uses the portable Mac client and authoritative shared DTOs,
so it does not claim a full legacy Mac Store tag round-trip. Mobile categories remain
separate and the process test checks them after mobile edits and note resolution.

The reference framing has a 16 MiB message limit, five-second socket timeouts and no
authentication/versioning. Listeners bind ephemeral loopback ports only. Their fixture
controls are intentionally non-deployable. Baselines/rebuilds scan a bounded synthetic
library, assets/history are retained, and no production performance or power-loss
claim follows from the checks. All runtime databases, files and simulator captures
belong to disposable task fixtures.
