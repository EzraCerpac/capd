# Capd sync server

`capd-sync-server` hosts the prepared CapdSync HTTP boundary on macOS 15 or newer. It listens only on `127.0.0.1` and exposes `POST /v1/sync`. It does not include the reference fixture controls, client activation, pairing, credential issuance, migration, TLS termination, or service installation.

An HTTPS reverse proxy is required before remote clients can use this listener. This package is local integration preparation; NAS deployment and client enrollment remain separate work.

## Build locally

The package requires Swift 6.2 or newer. The local preparation used the installed Xcode Swift 6.4 compiler. Swift Collections is pinned to 1.3.0 because newer Span helpers failed to compile with that Xcode preview. Dependencies are isolated here; the portable CapdSync package has no web framework dependency.

From the repository root:

```sh
xcrun swift test --build-system native --package-path Packages/CapdSyncServer
xcrun swift build --build-system native --package-path Packages/CapdSyncServer \
  --configuration release --triple x86_64-apple-macosx15.0
```

The native SwiftPM backend is selected explicitly for cross compilation. Verify the resulting executable instead of assuming the requested triple was honored:

```sh
file Packages/CapdSyncServer/.build/x86_64-apple-macosx/release/capd-sync-server
xcrun vtool -show-build Packages/CapdSyncServer/.build/x86_64-apple-macosx/release/capd-sync-server
otool -L Packages/CapdSyncServer/.build/x86_64-apple-macosx/release/capd-sync-server
```

SwiftPM links package libraries into the executable. macOS system frameworks and runtime libraries remain dynamic; this is not a fully static binary. Some Xcode toolchains also link the back-deployment shim `libswiftCompatibilitySpan.dylib`. Prepare the transferable bundle with:

```sh
Packages/CapdSyncServer/Scripts/build_intel.sh
```

This copies the executable into `.build/artifacts/capd-sync-server-macos-intel` and, when linked, includes the Intel shim and rewrites its load path. It removes the build Mac's Xcode runtime search path and signs the packaged files ad hoc. Keep the bundle intact; a `.tar.gz` with a short run note is also produced in `.build/artifacts`. A toolchain that links the shim must supply it at the script's expected Xcode location. The SDK redirects `libswift_errno`, `libswift_stdio` and `libswift_signal` to `libswiftDarwin` for targets below macOS 15.0. The `$ld$previous` end-exclusive range follows [Apple's linker implementation](https://github.com/apple-oss-distributions/ld64/blob/main/src/ld/parsers/generic_dylib_file.cpp#L265-L321); an Intel 14.0 versus 15.0 linker probe confirmed that transition. These remain OS dependencies. This verifies the SDK target contract, while actual NAS availability and execution remain unverified.

Local Intel execution under existing Rosetta checks the executable on the build Mac; it does not verify a NAS runtime.

## Configuration and storage

Both `--config PATH` and `--data-dir DIRECTORY` are required. There are no environment credential overrides or live-library defaults. `--port` defaults to 8080; `--port 0` chooses an ephemeral port. Readiness prints the actual loopback port. `--help` needs no configuration.

```sh
capd-sync-server --config /owned/path/enrollment.json \
  --data-dir /owned/path/new-sync-data --port 8080
```

The JSON schema is strict. Unknown fields, empty enrollment lists, zero identities, duplicate device IDs or credential digests, and malformed digests fail validation. Every enrollment has all four fields:

```json
{
  "serviceID": "11111111-1111-4111-8111-111111111111",
  "enrollments": [
    {
      "libraryID": "22222222-2222-4222-8222-222222222222",
      "deviceID": "33333333-3333-4333-8333-333333333333",
      "credentialSHA256": "REPLACE_WITH_SHA256_DIGEST",
      "revoked": false
    }
  ]
}
```

This example is deliberately invalid. The bearer format is 64 lowercase hexadecimal characters generated from 32 random bytes. Only its SHA-256 digest belongs in configuration; plaintext bearers must stay out of arguments, configuration, source, and logs. A digest cannot demonstrate that its originating bearer had sufficient entropy. Secure issuance, delivery, and Keychain-backed client storage are not implemented here. Treat this verifier configuration as sensitive and restrict its file permissions.

Configuration is reread and fully validated on every request. Setting an enrollment's `revoked` field to `true` invalidates that device's bearer immediately for later requests. Keep a revoked entry when disabling the final device. Replace the configuration atomically. Missing, unreadable, malformed or changed-service configuration fails closed with a generic 503 response. Changing the service ID requires a new data root, rather than reassigning old storage.

The data directory must be fresh and empty, or already contain this service's matching `service.json`. An empty abandoned `.server.lock` file is also accepted. Unrelated nonempty directories are refused before adding files. One running host holds an exclusive lock. Library directories, SQLite databases and blob paths are derived from enrolled UUIDs, with persisted core ownership bindings; existing direct symlink aliases are refused. Use only storage owned by the service account.

Backups and restores must preserve the complete data directory, SQLite databases and asset folders including their ownership markers, along with the stable service/library configuration identities. Shut down cleanly for an offline copy, or use a coordinated SQLite-safe backup strategy. The listener does not import unbound client libraries. Populated libraries use the separate reviewed [content import and application handoff](../../docs/designs/library-migration.md) flows.

## Limits and checks

Body collection is bounded at 16 MiB before converting to Foundation Data. Blob upload chunks are bounded at 64 KiB. Eight requests may collect or wait for work at once; further requests receive 503. SQLite, configuration and file work run on a dedicated serial queue, outside NIO event loops. Duplicate Authorization or Content-Type headers are rejected before flattening. Error responses omit underlying storage errors and credentials. Unknown paths and non-POST methods use Hummingbird's default routing responses.

The full baseline remains a single bounded JSON response; libraries exceeding its response limit receive 503 `resourceLimit`. Capture and website-icon baselines also support bounded, cursor-pinned pages with total counts that clients verify before accepting a complete baseline. Website-icon requests require envelope version 5 and authenticated icon capability version 1; older servers continue capture sync without icon delivery. Aggregate storage/history quotas, request-rate policy and automatic receipt pruning are not implemented. The listener also needs deployment-specific proxy timeouts and access controls. SIGTERM/SIGINT use Hummingbird's graceful service shutdown.

The process check generates disposable credentials and synthetic data, binds only loopback, restarts the host, and removes its own resources:

```sh
uv run --no-project --python /usr/bin/python3 \
  Packages/CapdSyncServer/Scripts/process_smoke.py \
  .build/artifacts/capd-sync-server-macos-intel/capd-sync-server
```

It checks authentication and identity gates, duplicate headers, body limits, exact operation retry, baseline/feed, blob transfer, immediate revocation, persistence across restart, service binding and graceful SIGTERM. It never contacts the NAS.

## Optional assistant bridge

Pass both `--mcp-bridge-config PATH` and `--mcp-socket PATH` to enable the separate private Unix-socket bridge. Omitting both preserves the sync-only listener. The socket uses mode `0600` and requires the same service user; its parent directory must be privately owned. An existing socket is refused rather than replaced. The host removes its socket during graceful shutdown.

The strict bridge policy contains `version: 1`, `serviceID`, `libraryID`, an HTTPS `resource` ending in `/mcp`, `principalID`, `credentialSHA256`, `scopes`, `revoked`, and a `writerDeviceID` when `capd:write` is granted. Read access requires `capd:read`; create/edit access requires both scopes. The verifier and writer identity must differ from every ordinary sync enrollment. The authority persistently reserves the writer UUID for its principal and refuses UUIDs with prior sync-device history, including removed enrollments. Reserved UUIDs cannot write through ordinary sync or transfer to another principal. An existing bridge writer with unreserved history requires a fresh writer UUID. Keep the policy owner-only and replace it atomically; each request reloads policy on the authority queue.

The ordinary sync listener and private MCP socket each admit up to eight bodies independently. Incomplete sync bodies cannot consume the private bridge's admission slots.

`capd-mcp-stdio --credential-file PATH --socket PATH` bridges JSON-RPC over stdin/stdout to that socket. Its credential file is separate from device-sync credentials and any external tunnel credential. No new public HTTP route or OAuth issuer is enabled by these flags. See `../CapdMCP/README.md` for tool schemas and limits.
