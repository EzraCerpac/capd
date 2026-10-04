# Safe mobile library activation

This implementation connects a preserved local prototype library to an already
authorized service/library. It does not create a service, library, device grant,
certificate, profile, App Group, or host import endpoint. Physical-device setup and
the actual host import remain separate, explicitly coordinated operations.

## App and share sessions

`MobileEnvironment.session(role:)` opens `MobileLibrarySession`. Both roles select
the same version-1 `active-library.json` in the existing App Group. Its public
metadata is generation, HTTPS enrollment, binding, fresh device UUID, and a fixed
relative database path. No credential is encoded in it. An absent selector uses
the original `Library/captures.sqlite`; malformed or symlinked selectors fail.
Connected stores are `ConnectedLibraries/<generation>/captures.sqlite`.

The app gets `EnrolledSyncAdapter` only with an exactly matching bound store and
device identity. Share gets `LocalOnlySyncAdapter`, writes the same bound store and
outbox, and never reads Keychain or connects to the network. Its existing
`MobileEnvironment.store()` compatibility call resolves this shared selector.
The old globally gated adapter initializer remains closed; no guard was removed.

Each managed store read/write and entire sync request holds a shared nonblocking
filesystem lease. Activation holds an exclusive lease through publication,
reopen validation, and rollback. A stale session throws `sessionReplaced`; a
concurrent cutover throws `transitionBusy`, retaining the share/composer draft for
retry. Database pools still serialize app/share outbox sequences through SQLite.
`AutomaticSyncController.suspendAndDrain()` cancels timers/requests and waits for
the actual in-flight transport to finish. Foreground/retry cannot restart it during
the drain. LibraryModel drains, reopens the selected session, replaces its state
listener/connectivity monitor, and resumes only when the scene is active.

## Preparation and host handoff

Preparing briefly fences writers and retains, under
`ConnectionBackups/<snapshot UUID>/`:

- `Original/captures.sqlite`: a coherent SQLite backup including committed WAL
  content, identity, cursor, exact outbox/receipts, projection and FTS.
- `Original/assets`: the original local asset files, including incomplete files.
- `OriginalRaw/captures.sqlite` and optional `-wal`: the quiesced original bytes.
- `Transfer/snapshot.json` and digest-named `Transfer/assets`: full visible content,
  including overlays/tombstones, plus verified referenced attachments.
- `preparation.json`: retained manifest, fresh enrollment UUID, creation time and
  logical source-state fingerprint. It contains no credential.

Only `Transfer` is exported. It excludes original operation history. The source
database, WAL and pending operations are not reset, acknowledged or replayed. The
usable archive keeps original sequence gaps (for example accepted sequence 1 and
pending 2/3). Preparation is retained across relaunch. Incomplete preparations are
retained but are never offered for activation. Further source changes require a
new preparation and review; activation rechecks identity, full logical history,
exact visible snapshot and retained manifest before contacting the authority.

Reuse `Packages/CapdSyncAdmin`'s offline preview/import CLI,
with a stopped host and its existing exclusive lock. The transfer bytes are sorted
JSON with the shared default date encoding. The admin raw snapshot SHA and shared
contract digest therefore agree for an unchanged export, but remain distinct
contract fields; altering whitespace invalidates the raw hash.

Bring back the exact `SnapshotReview` and committed
`ContentSnapshotImportReceipt`. `MobileSnapshotReview` is wire-compatible with
that host artifact; the phone does not link the host administration package.
The UI displays competing values, differences, tombstones, maximum-known lower
bounds and feed expiration, and requires explicit review/connection approval.
Supply the review and receipt SHA-256 pins separately from the coordinated host
result. A file or its embedded digest cannot approve itself. The host CLI prints
the review hash; the coordinator must separately pin the exact receipt stdout bytes.

The phone verifies manifest/snapshot ID, contract digest, target binding, original
device ID, count policy, cursor transition, complete one-to-one source/canonical
mappings, unique item IDs and original note provenance. These are administrative
preservation receipts, never acknowledgements of the original pending operations.
The grant is for the new device UUID shown in the preparation, not the source UUID.

## Activation and rollback

The app's explicit activation checks an authenticated baseline with metadata and
generated-processing capabilities. It rejects reused device sequence history and
requires the reviewed canonical imports/tombstones/tags/note variants to be present.
It creates a new bound store and pulls the authority (expired-feed recovery loads
the baseline after snapshot import). No old pending operation is sent. A second
authenticated preflight rechecks the new identity and import before publication.

Only then does Keychain receive the approved device credential. The additive
`SyncCredentialCreationStore.insertIfAbsent` uses atomic `SecItemAdd`; it never
updates an existing account. An identical interrupted attempt can be reused, but a
different or unreadable value is refused and retained. Synthetic tests use memory
credentials. Share has no credential access.

The connection screen can generate 32 random bytes with the system secure random
source. The bearer stays in view memory until verified activation stores it; only
its SHA-256 verifier is displayed for the separately approved host grant. Leaving
the screen clears that memory. An unused host grant must be revoked before making
a replacement credential. This button creates no host grant and does not authorize
an import or bypass the reviewed receipt requirements. The Keychain service is
`dev.jxd.capd.phone.sync`, with the service/library/new-device tuple as account.

Publication uses atomic selector replacement under the exclusive lease. The bound
store/adapter are reopened before the lease is released. A publication/reopen
failure restores the prior selector before any share can observe the new store,
and removes only the credential created by that attempt. Both original and staged
libraries remain. A failed selector restoration or credential cleanup has an
explicit error; neither is hidden. A local rollback does not undo a committed host
import. Its stable snapshot ID allows the admin tool to recover the exact receipt.
An empty original library uses authenticated enrollment without inventing an empty
snapshot import (the authority's snapshot API intentionally rejects empty input).

An explicit `keepArchivedOnly` choice also permits a populated original library
to remain local while the fresh bound library is populated solely from the
authenticated authority. This path refuses an import handoff, still verifies the
retained preparation and unchanged original history, requires a fresh authorized
device identity, and retains the original database, exact outbox and backup.
It neither deletes nor acknowledges old operations and makes no authority import.
The default remains `importReviewed`; the connection UI requires an explicit
archive-only selection before omitting the import review and receipt.

## Projection and revision foundation

`LibraryModel.librarySession` exposes the selected session. Session saves and reads
return the canonical capture with its generation and binding. Managed store access
holds the same generation fence used for activation.

The preserved store schema includes a transactional `mobile_system_search` UUID
revision marker. Every local or remote projection updates it in the same database
transaction. Snapshot and acknowledgement APIs, a repair journal, and a search
lease remain portable foundation; the app and share extension do not index or
donate captures to an operating-system service in this client.

The connection screen can send a credential-free, bounded HTTPS request from the
device. HTTP 401 establishes reachability to an authentication boundary, not the
service/library identity; activation still performs its authenticated checks.
No enrollment, Keychain access, import or network configuration occurs during this
probe. An installed VPN app or a Mac-side probe is not evidence of phone reachability.

Debug builds support a paired-device preparation handoff. Launching with
`--capd-export-preparation` copies the latest retained preparation, including its
private original database archives, under `Library/ConnectionPreviews/<UUID>`.
This location is accessible through CoreDevice's supported App Group file service;
the original `ConnectionBackups` directory remains intact. These private archives
are distinct from the ordinary UI's content-only `Transfer` export.
`Library/connection-preparation-result.json` reports the selected public library
configuration, snapshot/device IDs, manifest digest, export location and errors.
`--capd-prepare-connection <HTTPS endpoint> <service UUID> <library UUID>` first
prepares a new snapshot. The optional `--capd-check-private-endpoint` performs the
same credential-free probe as the UI. Neither path generates a credential,
imports content, grants access, or activates a library.

## Validation

The portable mobile fixtures cover original outbox and raw DB/WAL retention,
restorable projection, app/share session reopening, canonical alias saves, stale
session rejection, handoff pins and authenticated import checks, fresh sequences,
atomic credential creation, publication rollback, archive-only activation, exclusive
leases, and cancellation/drain behavior.

`LibraryConnectionUITests` is opt-in using
`CAPD_ACTIVATION_OWNED_SIMULATOR=<SIMULATOR_UUID>`. It prepares/reopens synthetic
backups and exercises an external share with the app closed. Simulator execution
requires local ad hoc signing so the existing App Group entitlement is embedded.
The ordinary unsigned simulator build compiles the app and share extension without
installing either target or opening a simulator.
