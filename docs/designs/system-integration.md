# Local system search and capture actions

`CapdSystemIntegration` is an iOS 17/macOS 14 package with no dependencies. It contains Core Spotlight indexing, stable capture references, strict URL/activity routing, and foreground App Intents. It does not read a capture store, start indexing, request Siri access, or send data over a network. A host supplies a complete canonical local snapshot and explicit system-search consent. The phone entrypoint installs the bridge and receives URLs/Spotlight activities. The Mac and phone hosts supply navigation, draft presentation, consent settings, and store projection hooks.

## Actions and privacy

Find Captures opens local search. Open Capture resolves a stable library/capture UUID against the current host before navigation. Draft Text Capture stages the text supplied in an explicit invocation for review; it never saves a capture. Search/open require the host's system-search consent; drafting text is independent. Entity queries return at most 20 matches and no unsolicited suggestions. There is no content/result dialog, model invocation, assistant schema, clipboard read, or ambient listening.

Each app has one app-level shortcuts provider with three phrase templates and an `AppIntentsPackage` wrapper for package discovery. Foreground execution uses `supportedModes` on iOS/macOS 26 and `openAppWhenRun` for older supported versions. Absent/uninitialized hosts return an unavailable error. Cancelled tasks are checked before routing. Drafting is synchronous and reversible; the host must only show a composer, never persist from the callback. System cancellation after dispatch, Siri discovery, locked-device behavior, and cold app launch require signed-app verification on each OS. App Shortcuts are named actions; they do not implement arbitrary Siri generative Q&A.

## Index behavior

The named `CSSearchableIndex` uses `FileProtectionType.complete`. Current macOS/iOS 27 exposes the protection property, checked by the synthetic test. Older macOS versions may differ in protection enforcement; no locked-device test has been performed. IDs are `capd.v1.<library UUID>.<canonical capture UUID>`, independent of device IDs/local row numbers. Domain IDs include the library UUID. Never use a local `Int64`, device UUID, URL, or content fingerprint as the searchable identifier. Sync aliases must already be canonicalized in the supplied projection. The same record from two devices must have the same library/capture IDs; replacement of an alias in a complete snapshot removes its old item.

Reconciliation serializes operations, removes absent/tombstoned IDs, updates changed items in place, and makes no repeated donation for unchanged snapshots. Higher revisions win within a snapshot; a tombstone wins a tie. Conflicting duplicate data at one revision is rejected. Snapshots are limited to 1000 records, title to 256 characters, text to 8192, and 32 keywords of at most 80 characters. Initialization truncates values and the reconciliation/backend boundaries validate decoded or mutated inputs. Do not truncate a library to fit the snapshot limit: if a complete usable snapshot cannot be built, deactivate system search and report the error. Avoid out-of-order snapshots by refreshing through one host/coordinator after committed local changes and sync projection.

A coordinator's first enabled reconciliation clears only its own library domain and rebuilds from the canonical snapshot, removing stale IDs left by a previous process. A new process does not trust an in-memory manifest. Items expire after 30 days as an additional bound; expiration is not a substitute for immediate deletion. The host must reconcile after delete, merge, and sync tombstones, and refresh on foreground/launch. Keep one coordinator/backend for a library's named index. This package has no background reindex delegate extension, recovery scheduling, or autonomous background worker. Operation completion is journal acceptance; Spotlight visibility is asynchronous.

Disable the host immediately and call `await bridge.deactivate(using: coordinator)` on consent revocation/library removal before changing libraries. This clears runtime data and awaits scoped domain deletion, even if the calling task is cancelled. Surface deletion errors and retry until confirmed; never silently report revocation complete on failure. A bridge refuses switching to another library until deactivated. Delete individual IDs or this library's domain only. No global Spotlight deletion API is used.

## Phone wiring

The XcodeGen project includes the package, phone App Shortcuts provider, strict
`capd` URL routes, and Spotlight user activity handling. `PhoneSystemSearch`
receives the entire selected session projection, independently of the visible
query. It indexes saved titles and manual tags after explicit opt-in. The share
extension records a transactional revision marker; the app reconciles after it
next opens. The host owns OS writes and the durable repair journal.

Library replacement drains search work under the generation/search leases before
activation. Failed domain deletion retains its repair scope. Opt-out invalidates
routing immediately and serializes scoped deletion. Oversized libraries fail
closed. Find changes the local filter; Open re-resolves the current capture;
Draft Text opens the ordinary composer and requires Save. Failed reconciliation
retains a cold-launch route for retry while search consent remains active. Find
returns the shared navigation stack to the library root before applying its filter.

## Mac wiring

`MacSystemSearch` installs the action host. `AppState` routes recognized search
URLs before share handoffs and receives Spotlight activities through the app
delegate. Settings starts system search off and surfaces maintenance failures.
Route failures appear immediately through the existing HUD.

`MacDiscoverySnapshot` reads a complete bounded projection through
`MacLibrarySession.readOnlyStore(paths:)`. Bound libraries use persisted canonical
IDs; unbound libraries use a persisted local library identity without backfilling
store mappings. Query/detail paths reopen the read-only store per request.
Mutations retain the actual runtime session. Search/entity/open actions do not
start a sync client, access Keychain, or contact a service.

Both projections replace text titles matching the first 80 characters of the
trimmed source selection with “Saved text.” Title origin is not stored, so an
explicit title matching that prefix is conservatively redacted too. Source text
and stored titles remain unchanged.

Identifier batches resolve from one validated Mac snapshot. The unbound local
library UUID follows the database file's filesystem device, inode, and creation
time, persisted in preferences and checked for every snapshot. Database
recreation or atomic replacement rotates that UUID, so old saved references
report missing. An in-place overwrite preserving those filesystem attributes is
outside this detection. Discovery remains read-only and does not add schema or
store mappings. A failed Spotlight batch forces a scoped domain rebuild on the
next reconciliation, including any items partially accepted before the failure.

Search routes show the existing search window. Open resolves UUIDs to current
local rows. Draft Text presents editable text and saves only after confirmation.
The package and app providers compile App Intents metadata; a bare SwiftPM
executable build does not establish signed-app shortcut discovery.

## Validation

Local compilation and tests use Xcode 27 / Swift 6.4. No older SDK is installed in
this environment. The SDK 27-only protection-class diagnostic getter and its
entire test declaration are guarded by `compiler(>=6.4)`; Swift 6.2 builds omit
that diagnostic. The normal named-index initializer still requests `.complete`
on all supported toolchains. CI's Xcode 26.3 selection is unchanged.

Unit tests use an in-memory index and synthetic fixtures. The opt-in `CAPD_SPOTLIGHT_SYNTHETIC_SMOKE=1` test uses a newly generated `dev.jxd.capd.synthetic.<UUID>` named index/domain, donates one synthetic item, queries only that domain, and deletes that domain. It catches errors and attempts scoped cleanup. Normal tests skip this system write test.

```sh
CLANG_MODULE_CACHE_PATH=/tmp/capd-system-module-cache swift test \
  --disable-sandbox --package-path Packages/CapdSystemIntegration \
  --cache-path /tmp/capd-system-swift-cache --scratch-path /tmp/capd-system-build \
  -Xswiftc -disable-sandbox
```

The compiler flags avoid nested sandbox failures while the execution environment's workspace restrictions still apply. The system smoke test requires access to macOS's indexing helper. Tests do not enable Siri, voice, accounts, Apple Intelligence, or index private captures. No physical-device installation is performed.

## Apple references

- [Core Spotlight index](https://developer.apple.com/documentation/corespotlight/cssearchableindex): private on-device index, named indexes and APIs.
- [Searchable items](https://developer.apple.com/documentation/corespotlight/cssearchableitem): unique IDs and domain grouping.
- [Support semantic search with Core Spotlight](https://developer.apple.com/videos/play/wwdc2024/10131/): local privacy, recovery and journal/visibility behavior.
- [App Intent supported modes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes): modern foreground behavior.
- [App Shortcuts provider](https://developer.apple.com/documentation/appintents/appshortcutsprovider): named phrase actions.
- [Cancellable Intent](https://developer.apple.com/documentation/appintents/cancellableintent): newer system cancellation API, beyond the package's minimum deployment targets.
- [Bring your app to Siri](https://developer.apple.com/videos/play/wwdc2024/10133/): schema-based discoverability, separate from basic App Shortcuts.
