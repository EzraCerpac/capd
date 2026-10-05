# Phone search integration

`CapdSystemIntegration` supplies stable references, strict routes, foreground
App Intents, and named Core Spotlight indexing. The phone project supports iPhone
and iPad; its saved-source rows retain the shared adaptive styling.

`PhoneSystemSearch` receives the selected session from `LibraryModel` and reads
a compact discovery snapshot, independently of the visible search filter. Bound
libraries use
the persisted library UUID; unbound libraries use a stable local UUID. Saved
titles and manual tags are the only indexed content. Source bodies and notes are
excluded. The named index uses complete file protection.

The discovery read shares one SQLite snapshot for its dirty revision, size checks
and selected records. It counts at most 1,001 live rows before decoding and omits
body, OCR, note, conflict and metadata payload columns. Retained titles have a
4 KiB budget, tag JSON 16 KiB, each metadata record 32 KiB, and the whole snapshot
8 MiB. Selection returns at most 4 KiB; a shortened prefix needs more than 80
trimmed graphemes to prove the exact derived-title prefix. Ambiguous prefixes and
oversized metadata fail closed rather than relaxing title privacy.

Consent starts off. Settings shows updating, ready, off, or an actionable failure.
Opt-out invalidates routing immediately and serializes scoped index deletion.
The repair journal retains library scopes before OS writes and retires them only
after confirmed deletion. Session-generation changes rebuild the index. The share
extension writes a transactional revision marker; the app reconciles after it
next opens or prepares an intent. Libraries that exceed 1,000 live captures or
discovery metadata budgets retract their indexed domain and retain the repair
record if deletion fails. Indexed items have no fixed expiration;
reconciliation and consent withdrawal manage their removal.

Strict `capd://find` and `capd://open` links and Spotlight activities resolve
through the current host. The app connects its selected-session model before
installing the intent host. Cold routes and intents wait for the complete snapshot
and obey consent. Find changes the filter; Open resolves the saved capture again; Capture
Text stages an unsaved draft. No intent starts network work.

Portable tests use synthetic stores and memory index backends. The OS smoke test
and iPad UI tests are opt-in. An unsigned generic simulator build verifies
compilation; it does not establish signed-app shortcut discovery or actual OS
query results. Spotlight tag-only query behavior remains unresolved.
