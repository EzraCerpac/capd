# Self-hosted sync preparation

`CapdSync` implements a versioned, authenticated HTTP boundary and durable
service/library enrollment checks for a self-hosted library. Mac and iPhone
clients start unconfigured and activate only after verified enrollment. Hosting,
HTTPS routing, device grants and backups require separate operator setup. The
reference socket remains a separate synthetic fixture.

## Prepared boundary

`SyncHTTPHandler` accepts `POST /v1/sync` with `Content-Type: application/json` and
an opaque bearer credential. Its injected `SyncAuthorizer` returns a server-owned
`SyncPrincipal`: service UUID, library UUID and enrolled device UUID. Token issuance,
expiry and revocation belong to that authorizer's host. The portable package has no
token database, network listener, TLS configuration or static production secrets.
The separate `CapdSyncServer` package supplies a loopback HTTP host and a digest-only
enrollment-file authorizer; see its [README](../../Packages/CapdSyncServer/README.md).

The JSON envelope carries a version, an action and expected service/library/device
UUIDs. Those UUIDs assert the client's enrollment; they never select server storage.
The handler compares them to its configured service identity and authenticated
principal before looking up a library. An apply operation must also name that
principal's device UUID. The provider selects a `SyncServer` from the authenticated
library UUID, and the handler verifies its persisted service/library binding.

```mermaid
flowchart LR
    C[Bound client and durable outbox] --> E[Versioned HTTP envelope]
    E --> A[Authorize bearer credential]
    A --> S[Verify service, library and device assertions]
    S --> L[Authenticated library authority]
    L --> D[Library SQLite database and owned blob directory]
    L --> R[Scoped response and exact operation receipt]
    R --> C
```

The handler accepts envelope versions 1 through 5 and rejects actions requiring a
newer version than the request advertises. Capture actions are apply, changes,
baseline, baselinePage, upload and download. Website-icon actions are
applyWebsiteIcon, websiteIconChanges, websiteIconBaselinePage, uploadWebsiteIcon
and downloadWebsiteIcon. Fixture controls and administrative actions are absent.
Domain DTOs use their existing Codable
representation inside the separate versioned envelope; dates use JSONEncoder's
reference-date numeric representation and binary data uses base64. Version changes
need an explicit compatibility decision before clients are activated.

Cheap route, method and body-size checks precede authentication. Authentication
precedes JSON decoding, operation checks and storage access. Case-insensitive duplicate
credential headers are rejected. This boundary accepts the exact JSON media type;
a host must normalize any permitted media-type parameters deliberately. Request and
response JSON are bounded at 16 MiB, upload chunks at 64 KiB, feed pages at 1,000
changes, and blobs at the existing 8 MiB domain limit. Oversized full baselines fail
with a bounded resource-limit response. Clients recover through cursor-pinned
baseline pages with a required `totalCaptureCount` computed in the same read
transaction. They verify the total and UUID ordering before treating recovery as
complete; missing or inconsistent totals are invalid responses. Summary requests
use a zero page limit and carry the full count without records.
The HTTP host must enforce admission limits while reading the body, before buffering
it into the handler's `Data` value.

All replies are versioned JSON with `Cache-Control: no-store`. Success includes the
authenticated service/library/device scope. Authentication failures return 401,
identity mismatches 403, malformed/version failures 400, unsupported media type 415,
and oversized requests 413. Domain failures have stable error values: sequence/replay
or expired-cursor conflicts use 409, missing blobs 404, other invalid domain inputs
422, and connection failures 503. Unexpected storage/authorization errors become a
generic 503 response. Responses contain no raw errors, credentials or request echoes.

`SyncHTTPTransport` bridges a synchronous injected request executor to `SyncTransport`;
it is not a URLSession network adapter. It validates reply version, media type, size,
status and successful identity scope before returning a receipt. A lost response
leaves the original operation queued, and retry uses the existing idempotent receipt.

## Durable enrollment and storage

`SyncLibraryBinding` stores only a service UUID and library UUID, never a credential.
Enrollment is explicit through `SyncClient`'s optional binding argument. Binding is
recorded in the same database transaction that prepares its role/device identity.
Matching reopen succeeds; changing or omitting an existing binding fails. Bound
clients require a matching `BoundSyncTransport` and device UUID for push and pull;
unbound clients cannot silently use a production-bound transport. Client and server
transactions revalidate persisted binding, so a previously opened pristine unbound
handle fails closed after another handle enrolls the database. The server accepted
reader and blob entry points perform the same check.

First enrollment refuses a previously used unbound sync database, including nonzero
sequence/cursor/history, accepted or rejected work and aliases, even after its outbox
drains. Unbound blob bytes also block enrollment. This API does not migrate a populated
legacy Mac or mobile library. Application activation uses fresh scoped storage or the
separate reviewed [content import and handoff](library-migration.md) flows.

A server authority also persists the full service/library binding. Its blob directory
has an exclusively created ownership marker for that same binding, so two library
identities or services cannot silently share an asset root. Opening bound storage
without its binding fails. Reopening a bound database requires its matching blob-root
marker; a missing marker or directory fails before database preparation or directory
creation. Rejected database enrollment occurs before a new blob ownership marker is
written. Initialization fails closed if the marker is corrupt or its creation is
interrupted. Database and blob-root enrollment are not one atomic filesystem
transaction; failed new enrollment may require restoring the correctly paired storage.
The host caches at most 16 authority/BlobStore instances, evicting the least recently
used library before opening another. Evicted libraries reopen their durable state on
the next authorized request. It must not reuse existing unbound handles during enrollment.

## Host and deployment requirements

The standalone host targets macOS 15 or later. The Intel packaging script builds
the executable on a development Mac and includes required compiler compatibility
libraries. Keep that bundle intact when moving it to a compatible host. Local
Rosetta process checks establish synthetic host behavior; they do not verify a
particular NAS runtime, capacity or deployment.

The host binds only `127.0.0.1`, requires explicit configuration and a fresh or matching
owned data root, and reloads digest-only device enrollment for each request. Revocation
is checked before authority lookup. Eight requests may collect a bounded body or wait
for the serial authority worker; SQLite and configuration work run outside NIO event
loops. SIGTERM/SIGINT shut down the host gracefully. Synthetic process checks cover
authentication, identity/header/body rejection, exact retries, assets, revocation and
persistence across restart. No NAS deployment or personal data is involved.

Deployment still needs an explicit owned storage location, process supervision,
HTTPS proxy configuration and a tested backup/restore policy covering SQLite state
and the complete asset directory, including ownership markers, together.

Application clients implement scoped Keychain credential storage and the asynchronous
`URLSessionSyncTransport`. The transport requires a fixed HTTPS endpoint, uses system
TLS verification, refuses all redirects, bounds request/response bodies and deadlines,
and checks cancellation. The client validates the enrolled service/library/device
principal and required capabilities before accepting successful replies. Synthetic
loopback tests cover redirects, cancellation, response bounds, authentication failures
and exact retry; they do not verify a deployed proxy or NAS connection. See
[production client behavior](production-sync-client.md). Service-operator authorization,
secure credential delivery/rotation and deployment-specific connectivity remain
operator responsibilities; there is no automatic pairing or credential issuer.

Capture and website-icon baselines use bounded, cursor-pinned JSON pages.
Aggregate storage/history quotas, partial-upload
cleanup, automatic receipt/tombstone pruning and request-rate limits are not implemented.
Current in-process blob locking does not support multiple authority
processes staging the same root. The current tests establish synthetic protocol and
isolation behavior; they do not establish production performance, power-loss recovery
or background iOS delivery.

The Mac Store integration preserves shared metadata and verified assets during a
reviewed copy-only migration. Ordinary capture, annotation, delete, enrichment and
tagging writes enqueue their shared mutations in the same SQLite transaction as the
local projection. Local FTS and pipeline bookkeeping remain local. Legacy mixed
generated/manual tags still use a union/pinned representation, so their original
provenance cannot be reconstructed losslessly. See `mac-store-sync.md` and
`mac-sync-runtime.md` for the mutation boundary and activation requirements.

## Focused verification

Synthetic temporary databases and assets cover authentication/revocation before
storage lookup, service/library/device spoof rejection, provider mismatch, colliding
identities across isolated receipts/feed/baselines/blobs, accidental blob-root aliasing,
exact retry after a committed response is lost, bounded malformed requests/responses,
and immutable client enrollment with queued or previously acknowledged work. The
existing domain tests cover reconciliation and blob integrity. Mobile package tests
and a generic simulator compilation check default unconfigured API compatibility;
no live library, production account or deployed endpoint is used.
