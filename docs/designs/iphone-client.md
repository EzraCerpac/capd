# iPhone client and shared outbox

The iPhone app and extension select the same App Group SQLite/WAL database through
`MobileLibrarySession`. Without enrollment they use the original local library;
verified activation publishes a generation-specific connected-library selector.
`MobileStore` opens a GRDB DatabasePool, migrates its source projection, then
injects that same writer into `SyncClient`. Shared `sync_meta` allocates a device UUID once inside
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
Delivery is automatic after local changes, foreground/reopen and connectivity
return, with a bounded active pull cadence for remote changes.
Each pull cycle processes at most 100 pages and returns normally with its durable
cursor; later foreground polls continue the feed so queued pushes get a turn.
The coordinator coalesces matching request modes. Pull-only refreshes and
push-capable syncs run separately in sequence, with their own results.
Cancelling a joined caller ends only its wait; the caller that starts the shared
flight owns its cancellation. Scheduler updates carry a lightweight committed
library revision, so status-only updates do not reload capture text. Conflict
counts are cached until that revision changes.

## Scheduling and presentation

`AutomaticSyncController` debounces local changes by 0.35 seconds and polls every
30 seconds while active. Transient failures use exponential retry delays starting
at one second, with jitter and a 30-second cap. The third consecutive failure
shows attention while retries continue. Five consecutive failures, or the first
nontransient error, halt automatic retries. Foreground/reopen, connectivity return,
and explicit retry reset the failure count. Suspension cancels scheduled and
in-flight work; iOS background delivery is not guaranteed.

The library shows a dismissible local-only explanation for an unconnected
library and attention for persistent errors, rejected work, or note conflicts.
Routine sync, offline use, and retries remain quiet. **Device sync** exposes
connection details and the last completed update. **Retry connection** appears
only with an attention error. Locally available sources and an empty queue do
not establish server or peer-device acceptance. Rejected local data is retained,
but the mobile UI has no rejected-operation recovery tool. Icon-sync errors have
separate presentation and do not fail accepted capture delivery.

The scheduler and presentation policies are implemented in
[`AutomaticSync.swift`](../../Packages/CapdMobile/Sources/CapdMobile/AutomaticSync.swift)
and `SyncPresentationCopy` in
[`SyncPresentationView.swift`](../../iOS/App/SyncPresentationView.swift).

## Connection and transport

The replaceable adapter provides a `SyncTransport`. An unconnected library uses
the local-only adapter. A verified enrolled app session uses `EnrolledSyncAdapter`
with the authenticated HTTPS boundary; the share extension writes the same bound
store and outbox through `LocalOnlySyncAdapter`, without credentials or networking.
The connection UI prepares a retained backup, accepts a reviewed host-import
receipt or archive-only choice, and verifies the explicitly authorized fresh
device identity before activation. It does not create a service or device grant.
See [mobile library activation](mobile-library-activation.md) and
[production transport](production-sync-client.md).

A DEBUG simulator launch flag activates `ReferenceTransport`, a bounded framed
TCP connection to 127.0.0.1. The reference executable runs two separate processes:
an authority with its own GRDB database and a portable Mac `SyncClient` with its own
library, connected through that same transport. Its test controls inject socket
closure after commit and temporary connection refusal; these are synthetic network
failures, not a physical-radio or production-network test.

## Mobile capabilities

The iOS UI supports link/text capture, incoming and outgoing share, search,
manual annotations/tags, explicit note resolution, deletion, and device connection
configuration. Details display saved body/OCR/generated tags and capture metadata.
Restore, ratings editing, webpage enrichment, OCR execution, blob/image creation,
reminder scheduling, and taxonomy management have no mobile UI. Portable protocol
coverage does not imply those UI actions.

`PhoneWebsiteIcons` loads verified local assets and controls display through
**Show synced website icons**, enabled by default. New icon generation belongs to
the Mac Agent; the phone never requests icons from saved websites. See
[website icons](website-icons.md). `CapdDesignSystem` shares palette and typography
roles while mobile views keep native navigation, Dynamic Type, and adaptive
appearance; see [styling](iphone-styling.md).

Ask Cap retrieves saved local text and invokes Apple's on-device model on eligible
iOS 26 devices, with no remote fallback or persisted question/answer history.
Supporting quotes and citations are checked against supplied evidence; they do
not prove semantic correctness. See [local answers](iphone-local-answers.md).
Opt-in Spotlight and named Shortcuts expose titles/manual tags, with complete
bounded projection and explicit draft confirmation. See
[discovery integration](phone-discovery-integration.md).

## Fixture boundaries

Fixtures use fresh disposable libraries. Opening a legacy mobile database with a
`pendingCaptures` table is refused; the client does not migrate that old queue.
The existing internal Mac Store fixture adapter still projects mixed tags into its
legacy union/pinned column and its snapshot can promote generated tags to manual.
The reference-process test flow uses the portable Mac client and authoritative
shared DTOs, so it does not claim a full legacy Mac Store tag round-trip. Mobile
categories remain separate and the process test checks them after mobile edits
and note resolution.

The reference framing has a 16 MiB message limit, five-second socket timeouts and no
authentication/versioning. Listeners bind ephemeral loopback ports only. Their fixture
controls are intentionally non-deployable. Baselines/rebuilds scan a bounded synthetic
library, assets/history are retained, and no production performance or power-loss
claim follows from the checks. All runtime databases, files and simulator captures
belong to disposable task fixtures.

These fixtures describe source-level contracts and synthetic coverage, not the
current installed app or server state. They do not establish physical-device
network behavior, signed Spotlight/Shortcuts discovery, or native model quality.
