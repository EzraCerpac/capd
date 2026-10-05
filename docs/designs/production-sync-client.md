# Prepared HTTP sync client

`CapdSync` supplies a cancellable HTTP executor and durable async client entry points for Mac and iPhone. `AsyncSyncTransport` carries the enrolled library binding and device ID and sends a `SyncHTTPRequest` asynchronously. The synchronous reference API remains available for fixtures.

`URLSessionSyncTransport` accepts a fixed HTTPS `/v1/sync` URL without user information, query or fragment. It uses system TLS verification, refuses every redirect, disables cookies and credential/cache persistence, and owns an ephemeral session for each request. Requests and accumulated responses are limited to 16 MiB; declared oversized responses and streaming overflow cancel the session. Each request has a resource deadline. The internal loopback initializer is available to package tests through `@testable`, outside the public production interface.

The async client checks library and device binding before credentials or network access. It checks cancellation before requests, between attachment chunks, and before acknowledgement or cursor transactions. A cancelled or lost response keeps the original queued operation ID, sequence, predecessor and payload. A later sync retries that exact operation; the HTTP executor does not implement a retry loop. Requests queued during a flight remain durable for the next batch. Successful replies must match protocol version, response kind and enrolled principal. Authentication failures produce generic setup errors, without exposing credentials, response bodies or private capture content.

`SyncEnrollment` contains only public identity and endpoint metadata. `SyncCredentialStore` separates credentials from library databases. The Keychain implementation uses a service namespace plus service/library/device account identity, disables iCloud synchronization, and uses `AfterFirstUnlockThisDeviceOnly`. Reads, replacement and removal report generic failures. Tests and previews use `MemorySyncCredentialStore`; the preparation tests do not read or write real Keychain items.

## Legacy activation gate and bound-store integration

`SyncEnrollmentActivation.requireReady()` refuses activation through the legacy globally gated constructor. Transport support alone does not authorize or enroll an existing library. Higher-level clients must supply a separately validated bound-store opening and activation path; this guard does not describe whether those clients expose connection settings.

The store guard refuses enrollment of a used, unbound database. Migration and backup acceptance and an authorized cutover are required before connecting existing content. A client may open a separately prepared bound store after validating its identity and backup without removing the legacy global guard. The mobile activation layer documents that path in `mobile-library-activation.md`; merely importing this package does not migrate or connect a library.

## Verification

`AsyncHTTPTests` runs an actual loopback HTTP host with synthetic enrollment and disposable SQLite/blob directories. It exercises response loss after commit, exact-byte retry after reopening, cancellation while awaiting a committed response, additional queued work during that request, multi-chunk attachment upload and verified download, redirect refusal with zero target requests, declared/chunked response bounds, authentication failures, and binding guards. It also verifies that the legacy global activation guard remains closed.

Mobile setup and activation checks belong to the client layer. They use disposable synthetic libraries and do not require resetting an existing library.


## Shared metadata contract

`SharedCapture.createdAt` remains the immutable original capture time. Optional `metadata: CaptureMetadata` carries the original domain values `updatedAt`, `lastSeenAt`, `reminderAt`, and immutable `sourceAppBundleID`; absence remains absence. Delivery, projection and migration do not invent timestamps. Dates use the existing deferred `Date` JSON encoding (seconds since Apple's reference date), preserving the supplied `Date` precision, independently of server revisions and feed cursors.

`CaptureEdit.metadata: CaptureMetadataPatch?` updates only supplied `updatedAt` and `lastSeenAt`. A missing or JSON-null `reminder` does nothing; `ReminderUpdate.set(Date)` sets it and `.clear` removes it. Creation time and source application are not editable. `CaptureEdit.sourceContent: SourceContentPatch?` fills only a missing/empty title or selection and cannot change URL, kind, hash or blob identity. `CaptureEdit.generatedPatch: GeneratedContentPatch?` updates body and OCR independently with `TextUpdate.set(String)`/`.clear`; omitted tags do nothing and `[]` clears them. The legacy whole `generated` replacement remains supported; combining it with `generatedPatch` is rejected.

Record, source, generated content, metadata and note-conflict variant descriptive extensions round-trip through `unknownFields: [String: JSONValue]`. Known-key collisions fail encoding. Unknown edit, note-edit and patch fields fail validation rather than silently accepting semantics this client cannot apply. Unknown mutation and update enum cases fail decoding. Pending operation BLOBs are never re-encoded merely by reading, reopening, capability refusal or mobile schema upgrade.

Mobile schema `mobile-original-metadata-v3` adds nullable metadata and original-creation reference seconds. It backfills from existing `sync_visible` JSON without rewriting the outbox. The raw creation value avoids SQLite datetime precision truncation. The capture detail view displays the supplied last-updated, last-captured, reminder and source-application values. Reminder display does not activate scheduling on iPhone.

## Atomic Store integration API

The frozen API is:

```swift
SyncClient.enqueue(
    in db: GRDB.Database,
    captureID: UUID,
    mutation: CaptureMutation,
    baseRevision: Int64? = nil
) throws -> SyncOperation

SyncClient.init(
    writer: any GRDB.DatabaseWriter,
    blobs: BlobStore,
    deviceID: UUID? = nil,
    binding: SyncLibraryBinding? = nil,
    prepareProjection: @escaping @Sendable (GRDB.Database) throws -> Void = { _ in },
    project: @escaping SyncClient.Projection = { _, _ in }
) throws
```

A Store mutation must change its source row and mapping, then enqueue through the same writer's active transaction. The overload rejects a different writer connection (including another writer for the same database file), a call outside a transaction, binding mismatch and enqueue from projection. Source/mapping/outbox/sequence and projection errors must escape the outer transaction so all database changes roll back. The existing standalone `enqueue` wrapper remains available and delegates inside its own writer transaction.

`prepareProjection` runs inside initialization's schema/binding/device transaction, after the existing enrollment, role and device guards. It permits the migration owner to seed projection/baseline metadata atomically. It runs on every initialization; one-time imports must be idempotent or check their own persisted marker. Callback failure rolls back newly created schema, binding, device identity and seeded database rows. Binding/role/device are checked again after the callback. It does not bypass the used-unbound-library or unbound-blob guard. The caller owns cleanup of newly created external blob files on a failed seed transaction.

## Authority capability and upgrade ordering

`AsyncSyncTransport.importBaseline(credential:)` exposes a fresh authenticated baseline
for the Mac import handoff without constructing a client database or a synchronous
adapter. It requires metadata capability 1 and uses the same cancellation, size,
response-version and principal checks as ordinary sync. It submits no mutation and
does not enroll a device. The Store handoff additionally validates the initial cursor,
empty device history, copied rows, identity map and image bytes before attachment.
Baseline pages require `totalCaptureCount` on the wire. Both HTTP assemblers pin
that total with the cursor and device sequences and verify that every expected
record arrives before returning a complete baseline. `summaryOnly` explicitly
requests zero records while retaining the full total. Replies without this field
are rejected; this contract requires an upgraded authority.
Mac activation must call `importBaseline(credential:requiringGeneratedProcessingContract:)`
with `true` before committing Store binding or configuration. This requires both metadata
capability 1 and generated-processing capability 1 under the enrolled principal. The
default remains `false`, preserving the metadata-only import requirement.

Authenticated successful `SyncHTTPReply` messages remain response version 1 and add optional `metadataContractVersion: 1`. Both HTTP action executors freshly probe a zero-limit `.baselinePage` before submitting a create with metadata/descriptive extensions or an edit with metadata, source-content, generated-content patches or extensions. They validate status, JSON, response version and the enrolled service/library/device principal before trusting that capability. An absent or unsupported capability throws `unsupportedVersion`; malformed or incorrectly scoped replies throw `invalidResponse`, with no apply request and queued work retained. No capability result is cached.

Guarded applies use request envelope version 2. The upgraded handler accepts versions 1, 2 and 3, and requires at least version 2 for these metadata semantics before resolving storage; an old version-1 handler rejects version 2 before accessing mutation storage. This also refuses a server downgrade between probe and apply. Legacy operations continue to use envelope version 1 without the extra probe. Operation ID, sequence, predecessor and canonical queued payload bytes do not change across negotiation or retry.

Upgrade the authority to this contract before enabling clients that create metadata or send the new edits. Verify it advertises the capability under the correct enrolled principal. Then integrate the separately proven Store/mobile migration and backup path and authorize activation. Unconfigured clients remain local-only; an existing bound-store activation path does not bypass capability checks. This package does not update a server binary, enroll a real device or change a live library.

## Metadata and transaction verification

`MetadataAndTransactionTests` verifies original submillisecond dates, absent/set/clear semantics, independent generated edits and source hole-fill, extension retention, unsupported semantics, outer Store-like transaction rollback/sequence reuse, writer identity, projection rollback/feedback refusal and atomic initialization failure. `MetadataProjectionTests` verifies mobile annotation, reopen and upgrade preserve original dates, metadata, extensions and exact queued bytes.

The real-loopback HTTP suite exercises missing, malformed, unsupported and incorrectly scoped capabilities, preserved work on reopen, legacy requests, fresh per-edit checks, a downgrade between probe and apply, upgraded edits and lost-response exact retry with metadata. `AutomaticSyncUITests.testOriginalMacMetadataAppearsOnSavedCapture` displays synthetic Mac metadata in the owned iPhone simulator.


## Independent tagging completion

`GeneratedContent` adds optional `taggingProcessed: Bool?` and `taggingInputFingerprint: String?`. Absent markers remain unknown. The additive `GeneratedContentPatch.taggingProcessing: TaggingProcessingUpdate?` is the processing write interface: `.processed(inputFingerprint: String)` atomically sets true and the exact supplied fingerprint; `.pending` sets false and clears it. Omission changes neither marker. The descriptor leaves body, OCR and tags untouched unless those separate patch fields are explicitly supplied, so a zero-tag completion does not resend an older generated-content snapshot.

Fingerprints are opaque, nonempty values bounded to 256 UTF-8 bytes (`TaggingProcessingUpdate.maximumFingerprintBytes`), without normalization or shared hashing. The Store/runtime owner computes the complete TaggingInput fingerprint and treats true as completed only when that exact input fingerprint matches. A stale descriptor can retain an old fingerprint while preserving newer server content; the input comparison detects that stale completion. Retag invalidation uses `.pending`.

New create/full-replacement operations accept only unknown nil/nil, pending false/nil, or true with a valid fingerprint. Inconsistent, empty or oversized new markers and unknown descriptor enum/patch semantics are refused. Existing descriptive records remain readable and retained even if an old processed flag lacks its fingerprint; this does not establish completion. A legacy whole generated replacement that omits both markers retains existing markers, matching prior extension preservation. Snapshot shape validation does not turn legacy descriptive marker values into new device-write claims; their original values remain preserved in the snapshot ledger.

Successful replies independently advertise `generatedProcessingContractVersion: 1`; `metadataContractVersion` stays 1. An operation carrying the descriptor or processing fields in create/full replacement freshly probes a principal-checked baseline for both capabilities, then uses request envelope version 3. Missing/unsupported capability refuses before apply; malformed capability refuses as an invalid response. A version-1/2 handler rejects version 3 before mutation, including a downgrade after the probe. The new handler requires version 3 for those processing writes before resolving storage. Existing metadata operations keep version-2 requests/probes, and legacy operations remain version 1; replies remain version 1.

Upgrade the authority with the processing capability before integrating the Store/runtime descriptor writes. This shared contract does not enable enrollment or update a live binary. `TaggingProcessingPatchTests` covers zero-tag completion, pending/reset/omission, legacy byte preservation, bounded consistent markers and stale marker independence. Synchronous and actual-loopback tests cover version enforcement, old metadata-capability compatibility, capability refusal/downgrade with unchanged queued bytes, and an exact retry after a committed stale-marker response is lost while newer body/OCR/tags remain intact.

`GeneratedContent.bodyIsThin: Bool?` and the corresponding patch field preserve extraction quality independently of body text. Omission is unknown; true marks incomplete text and false marks usable text. Classification requires a nonnil body. Body patches reset old classification unless they supply a new one, including clears and empty replacements. A classification-only patch can correct the quality of identical text. Legacy whole replacements retain quality only when they retain identical body text.

Quality-bearing writes probe `extractionQualityContractVersion: 1` plus metadata support, use envelope version 4, and require the quality capability on the receipt before acknowledging local work. Older authorities refuse before apply, and a lost or unsupported receipt keeps the exact operation queued for retry. Replies remain version 1; new readers accept omitted quality. This additive schema requires an upgraded authority for quality writes and does not promise old decoders can apply those writes. Authenticated import baseline readers can require the quality capability explicitly.
