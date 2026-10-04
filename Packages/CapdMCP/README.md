# Capd assistant MCP

This package supplies bounded assistant tools, strict authorization and a stdio bridge to the existing sync authority. The host exposes the bridge through a private Unix socket; it keeps one authoritative writer for each library. A separate HTTP/OAuth protocol kernel is available to integrations that provide an approved issuer and policy.

## Runtime boundary

`AcceptedStore` reads accepted records through a bound read-only GRDB connection. `MCPToolbox` validates tool arguments and routes writes through the existing `SyncServer`. `MCPStdioBridge` translates initialized JSON-RPC requests to the protected local socket. The sync server serializes this work on its authority queue and retains its data-directory lock. There is no second authority process or independent write database.

The private bridge policy has its own verifier, service/library binding, scopes and persistent assistant writer identity. It refuses a verifier or writer identity shared with ordinary sync enrollment. Policy and revocation are rechecked before each admitted request. The stdio executable reads its credential from an owner-only file; it never accepts the value through command arguments. See the sync-server README for the opt-in host flags.

## Tools and operation schemas

All objects reject additional properties. UUIDs are canonical 36-character UUID strings. Times are ISO 8601 whole-second UTC/RFC3339 strings such as `2026-10-04T10:00:00Z`. Numeric inputs must be integers in JavaScript's exact integer range. Limits are rejected outside range; they are not silently clamped. Query text uses literal case-insensitive AND terms, never SQL/FTS operators or arbitrary filters.

| Tool | Scope | Arguments |
| --- | --- | --- |
| `search_captures` | `capd:read` | Required `query` (1–512 UTF-8 bytes after nonblank check, at most 32 whitespace-separated terms); optional `limit` 1–20, default 20. |
| `get_capture` | `capd:read` | Required canonical `id`. |
| `list_recent` | `capd:read` | Optional `limit` 1–10, default 10. Created time descending, then UUID ascending. |
| `create_capture` | `capd:read capd:write` and policy-bound writer device | Required `operation_id`, `sequence`, `id`, `kind` (`text` or `link`), `created_at`; text requires nonblank `text` ≤16,384 bytes and disallows `url`; link requires credential-free HTTP(S) `url` ≤2,048 bytes, optional text. Optional `title` ≤512 bytes, `note` ≤8,192 bytes or null, `manual_tags` ≤20 strings of 1–64 bytes, `rating` 1–5. |
| `edit_capture` | `capd:read capd:write` and policy-bound writer device | Required `operation_id`, `sequence`, `id`, `base_revision`. At least one of `note` ≤8,192 bytes/null, `add_tags`, `remove_tags`, `rating` 1–5, `reminder_at` time/null. Tag arrays each ≤20 strings of 1–64 bytes and disjoint. Optional `resolve_note_operations` ≤20 UUIDs requires `note`; explicit resolution must match authority's current conflict set. |

`operation_id` and the exact arguments are the idempotency key. Read responses under the write grant expose `next_write_sequence` for the fixed policy-owned writer device. Concurrent writers may race; the server returns a sequence-conflict error with the expected sequence. Re-read state before a new request; retry an uncertain committed request using its exact operation ID, sequence, capture ID, created time, and payload. Do not change arguments under a retained operation ID. A create uses the operation ID as its initial note operation identity, making construction deterministic across retries and restarts.

Writes call `SyncServer.apply` only. Its transaction owns receipts, device sequence, feed changes, fingerprint aliases, duplicate recapture behavior, tombstones and note variants. Explicit note resolution validates the current conflict set and note revision in that transaction; a stale resolution consumes neither its sequence nor its operation ID. Stale notes become `noteConflict` with preserved variants; stale manual-tag changes use set merge, and ratings/reminders follow existing arrival-ordered metadata rules. `base_revision` is not a whole-record compare-and-swap; a future base is rejected. Generated body/OCR/tags, source identity, attachment bytes and arbitrary unknown fields are never writable through these tools. Capd reminders are capture metadata, not Apple Reminders creation. No delete, restore, import, arbitrary SQL, filesystem access, URL fetching, attachment download/upload, or FoundationModels ask tool is offered.

Read results contain canonical IDs and revisions, separate manual/generated tags, a `content_trust` marker, and truncation flags. Only accepted `sync_records` with `deleted == false` appear. Missing/deleted IDs use the same unavailable error. A repeated create receipt can predate deletion: response content is re-read from current authority state instead of leaking the old receipt body. Receipt outcome/revision remain historical, while any returned capture is current. A projection failure after commit returns the successful domain receipt with `capture_content_unavailable`, never a false failed-mutation result.

## Bounds and limits

- HTTP body ≤64 KiB, JSON nesting ≤32, string request ID ≤256 UTF-8 bytes. Kernel denies duplicate object members, batch requests and client responses. Host must cap headers (suggest 16 KiB), body collection before allocation, admission (reuse maximum eight), queue depth, token verification time, and request deadline. The kernel is synchronous and must not block a network event loop.
- Search/recent read at most 1,001 indexed-ID rows, fail closed if >1,000 total records (including tombstones), >8 MiB cumulative payload, or any row >256 KiB. Each oversized row is suppressed in SQL before loading its payload. This is a deliberate small-library ceiling, not an indexed full-text implementation. `get_capture` uses one primary-key row and remains usable beyond aggregate ceilings. An agreed indexed accepted-record reader is needed for large libraries.
- Search is newest-match first, not relevance-ranked. No claim of parity with the local Mac FTS service.
- Compact hit text budget 768 raw bytes; full text budget 24 KiB. Arrays/conflicts capped at 20 with truncation flags. Tool envelopes are measured after JSON encoding; above 60,000 bytes content falls back to IDs/revisions with `output_truncated`. HTTP adds bounded protocol metadata.
- Read-only connection uses a one-second busy timeout. Logs and persisted MCP state must contain no raw captures, tokens, tool arguments, or returned bodies. No MCP content cache or index is created.

## HTTP and authorization

Supports synthetic `2026-07-28` per-request metadata and legacy `2025-03-26`, `2025-06-18`, `2025-11-25` initialization. Modern requests require version and client-capabilities `_meta`, mirrored version/method headers, and a matching name header for tools. Missing/mismatched required headers return `HeaderMismatch`; unsupported modern versions list supported versions. `server/discover` and `resultType: complete` are supplied; no server-driven interaction/subscription capability is advertised. Legacy requests negotiate `initialize` and accept `notifications/initialized`; no session IDs or SSE streams are needed for this JSON-only subset. Authorized GET/DELETE return 405. Exact hosted client/date compatibility remains unverified.

The injected verifier must validate signature or opaque-token introspection, exact trusted issuer, canonical MCP resource audience, expiry and revocation; map the authenticated subject to the approved service/library, scopes and a dedicated persistent writer device. The boundary rechecks issuer, audience, binding, expiry, nonempty subject, and tool scopes on each request. ClientInfo, capture content, and caller arguments grant no authority. No fixture verifier is included in the production target.

`MCPJWTVerifier` implements a narrow ES256/`at+jwt` profile using pinned P-256 public keys and a freshly loaded `MCPJWTPolicyProvider`. It rejects token-supplied device IDs and validates the approved subject/client, signed capd library/service claims, lifetime and revocation on every request. The provider must atomically supply current trusted policy and fail closed on stale/unavailable configuration. It has no issuer, signer, network fetch or persistent secret storage. An RS256 or opaque-token issuer needs a separate verifier. This optional HTTP verifier is separate from the private-socket bridge policy.

Each write-enabled subject/client principal in a JWT policy needs a distinct nonzero writer device ID. Reusing one device across writers is refused before the policy can authorize requests. The toolbox persistently reserves each writer for its issuer, audience, subject and client identity before writing. A UUID with prior ordinary sync history is refused, and reserved UUIDs cannot write through ordinary sync or transfer to another principal.

Origin, if present, must exactly match the configured allowlist. Missing authentication returns 401 with RFC 9728 resource metadata discovery. Tool definitions explicitly declare OAuth scopes. Missing write scope returns 403 `insufficient_scope` with both read/write scopes and a tool error carrying `_meta["mcp/www_authenticate"]`; a read-only token sees only three read definitions. No scope is implied by another. Discovery at `/.well-known/oauth-protected-resource/mcp` advertises the exact approved resource and issuer. A production issuer still must implement authorization server metadata, client registration policy and OAuth consent (including PKCE/resource handling where required); this package does not implement those flows.

Example URI values in tests (`*.example.invalid`) are synthetic only. All endpoint, issuer, origin, audience and identity values must be agreed before deployment.

## Verification and deployment boundary

Run the package and host suites:

```sh
swift test --package-path Packages/CapdMCP
swift test --package-path Packages/CapdSyncServer
```

Synthetic tests cover scope and identity separation, revocation, accepted reads, exact write retry, changed-operation refusal, sequence conflicts, note variants/resolution, tag provenance, tombstones, historical receipts, argument and output bounds, JSON-RPC compatibility, credential-file constraints and Unix-socket behavior. `Tests/ProcessProbe/bridge_probe.py` exercises the compiled stdio and host processes against disposable storage.

A private deployment additionally needs an explicitly configured connector or tunnel, separate runtime credentials and an actual assistant read check. Installing these executables alone does not connect an assistant. No deployment configuration, real credentials, capture data or private runtime logs are included in this package. The bounded reader is intended for small libraries; suspended-client delivery and general-purpose hosted OAuth are outside this bridge.
