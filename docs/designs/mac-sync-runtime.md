# Mac library sync runtime

`MacLibrarySession.open(paths:)` is the shared Store factory used by the app,
agent and CLI. Without configuration, it opens the existing local library and
creates no sync client. With `sync-configuration.json`, it validates the persisted
library/service binding and device UUID before returning a bound Store. A bound
database with missing or mismatched configuration fails closed. It never falls
back to local writes. Every ordinary capture, annotation, generated result and
bulk tag rewrite uses the bound Store's transactional outbox.

The configuration holds version 1, an HTTPS endpoint, a library/service binding,
a device UUID and an enabled flag. It holds no credential. Production transport
uses the existing `KeychainSyncCredentialStore` service `dev.jxd.capd.sync` and
reads the matching credential for each authenticated request. Missing credentials
leave the Store bound and local changes queued; status reports attention. Paused
opening does not read the credential. Test injection is internal to CapdKit.

`MacLibrarySession.readOnlyStore(paths:)` opens SQLite read-only, performs no
migration, constructs no client or runtime, reads no credential and sends no
requests. MCP uses this factory and is excluded from CLI post-command flushing.
It is also the query-only factory for other read-only consumers.

## Synchronization and process ownership

`MacSyncRuntime` coalesces concurrent calls inside one process. Across app, agent
and CLI, `sync-runtime.lock` uses a nonblocking advisory flock with a close-on-exec
descriptor. Only its owner runs pull/push. Process exit or crash releases the
lease. Other processes continue transactional local writes and report busy; the
next owner sends their queued operations. All processes must use the same root.

Each cycle rereads configuration, uploads pending local operations before pulling
remote projections, and fetches a fresh credential per request. This ordering
keeps an unresolved local duplicate out of a conflicting pull projection. The
client preserves persisted operation bytes, predecessors, UUIDs and device
sequences through offline failures, cancellation, lost responses and restart.
Rejected operations remain inspectable and report attention in status, the app's
degraded indicator and CLI stderr. They are never discarded or resequenced.

The menu's conflicting-notes action shows each note's saved versions and an editable
merged note. Saving queues an explicit resolution using the displayed variant IDs
and observed revision. A newer, unseen version remains in conflict and requires
another review; saving locally does not establish remote resolution.

The app polls from a background sync actor every five seconds (30 seconds after
an issue). The agent syncs before processing incoming pending captures and after
writing generated results. Ordinary CLI commands try a five-second flush after
local work, including committed partial writes when the command returns an error;
a network problem does not undo the saved capture.
`capd sync run` waits up to 35 seconds and returns exit code 3 for offline,
attention or timeout. Cancellation joins the in-flight attempt before returning,
so its lease cannot leak. SQLite busy waits can add up to five seconds.
`capd sync status` is local state without networking.

## Incoming processing and invalidation

A new incoming text capture is enrichment-ready. A link with no generated body or
an image with no OCR stays pending; generated body/OCR makes an otherwise pending
row ready. Shared extraction quality keeps nonempty login/paywall bodies thin;
empty bodies remain thin and recapturing a thin body preserves its local retry queue.
Synced image captures reject data above 8 MiB before writing an asset.
Existing fetching claims are retained, and the bound agent startup
reclaims only claims older than the normal stale age. Claim writes select one
winner across processes. A completion from an obsolete claim does not overwrite
a newer claim; body/OCR received while its worker was running take precedence over
that worker's stale corresponding field.

Generated tags, body, OCR and processing status use independent merge patches.
Manual tags remain a separate category. Pull projection writes directly to local
rows and FTS without creating an echo operation.

A successful or refused tagging pass publishes `taggingProcessed=true` and
`taggingInputFingerprint`, including a successful empty tag list. The fingerprint
is `capd-tagging-input-v1:` plus SHA-256 of the UTF-8 JSON array of the exact
`TaggingInput` title, host, note, selection and 1,500-character body/OCR excerpt,
with null distinct from empty. An unchanged fingerprint suppresses repeat work.
A false marker or a mismatched fingerprint queues tagging, including captures
with manual tags; manual tags remain untouched. Missing legacy descriptors retain
the prior nonempty-tag behavior; empty unknown incoming results are eligible for
one processing pass. Processing state does not bypass pending enrichment.

Changes to those model inputs invalidate a descriptor. An old client generated
replacement without a descriptor preserves it on the server; a changed input is
still detected locally. Tagging completion compares its original input fingerprint
inside the Store write transaction and declines a stale result. A manual full
retag publishes pending markers, preserves manual tags and regenerates automatic
results. Taxonomy consolidation publishes processed markers for surviving mapped
tags and pending for dropped assignments. Mapping a pending result retains its pending status. Model changes require an explicit full
retag; local model and taxonomy versions are not globally synchronized.

## Activation requirements

The commands below describe a future explicitly approved live cutover. Testing
uses disposable synthetic libraries and injected credentials/transports only.
Nothing here authorizes changing an existing live Mac library or phone.

1. Quiesce every writer, including app, agent, CLI children and the share-extension
   relay. Capture and verify a WAL-safe SQLite plus full assets backup. Retain the
   exact prior configuration and the authority's corresponding backup/history.
2. Run the migration/backfill and initial authority import on verified copies.
   Check integer IDs, UUID mapping, device identity, counts, timestamps, metadata,
   manual/generated tag categories, nested image bytes and FTS. A populated Mac
   attaches only to its exact initial imported baseline (cursor 1, no device
   sequence history); ordinary enrollment continues to require an empty library.
   An empty fresh Store refuses a device whose authority sequence is advanced.
3. Confirm authority support for metadata contract 1, generated-processing
   contract 1/envelope 3 and extraction-quality contract 1/envelope 4,
   HTTPS connectivity and the exact service/library/device
   principal. Provision the device's matching credential in the shared Keychain
   service in a separately authorized step. Runtime activation does not create,
   save, delete or grant credentials.
4. Use matching updated app, agent and CLI binaries with the same `CAPD_DIR` root.
   Prepare public enrollment JSON containing `endpoint`, `binding` and `deviceID`.
   A Mac that already reaches this HTTPS endpoint through a trusted local SOCKS
   bridge may also set `loopbackSOCKSPort` (1–65535). This optional per-enrollment
   route uses only `127.0.0.1`, persists with the Mac configuration, and leaves
   endpoint identity, TLS verification, credentials and sync messages unchanged.
   It does not start a proxy, change system DNS/proxy settings, or configure the
   phone. Omission retains the ordinary direct/system routing behavior.
   With all writers stopped, run `CAPD_DIR=<prepared-root> capd sync activate
   --enrollment <public-enrollment.json>`. Activation acquires the sync lease,
   obtains an authenticated metadata- and processing-capable baseline, validates any populated
   handoff, seeds the bound Store and atomically publishes mode-0600 configuration
   inside the preparation transaction. A thrown installation/SQL failure rolls
   back binding, sequence, records and newly staged sync blobs, and restores exact
   prior configuration bytes.
5. Restart the matching writers. Run `capd sync status` and `capd sync run` against
   that root. Verify both directions, counts, identity, tags, FTS, nested images,
   pending/rejected work and generated processing before extending the cutover.

Configuration publication and SQLite commit are two durable resources. A power
loss after publication but before DB commit can leave configuration with an
unbound database. Opening fails closed in that state. With all writers stopped,
use the verified backup/configuration record to restore exact prior configuration
or retry the validated same-device activation. Never clear binding or invent
sequence history to repair it.

## Pause and rollback

`capd sync deactivate` waits for the current sync lease, atomically changes only
`enabled=false`, and retains library binding, device UUID, exact outbox and sync
history. Bound local writers keep queuing changes. `capd sync resume` validates the
same binding/device and resumes networking. Neither command unenrolls the library.

For a binary rollback, stop all writers and pause networking first. A pre-sync
binary cannot safely write a bound Store. Run read-only inspection on copies, or
restore a verified complete database/assets/configuration snapshot while all
writers remain stopped. Coordinate restoration with the authority's accepted
history; restoring an older local device counter against a newer authority can
replay the wrong history and is not a safe unilateral rollback. Never remove
configuration to obtain unbound writes. Any live restore, authority reconciliation,
credential change or physical-phone enrollment requires separate cutover approval.
The existing phone's user captures are outside this phase.
