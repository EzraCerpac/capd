# capd for iPhone

The client captures links/text, searches saved source rows, edits manual notes and tags,
resolves note variants, and deletes captures. The share extension writes to the same
App Group SQLite database while the main app is closed. The library refreshes when
active. Web fetching, OCR and image capture are not implemented in the mobile UI.

Device sync settings includes an opt-in for Spotlight and Shortcuts. It indexes
saved titles and manual tags. The complete library is reconciled after local edits
and sync projection, independently of the visible filter. Strict search links
support cold launch; Capture Text stages a draft requiring Save. Libraries over
1,000 captures fail closed. See [discovery integration](../docs/designs/phone-discovery-integration.md).

`Packages/CapdMobile` uses the shared `CapdSync` outbox, device identity and sequence.
There is no separate mobile pending queue or set-of-IDs acknowledgement path. Local
source rows and their FTS index are a transactional projection of accepted shared
records plus pending local edits. Manual/generated tags remain separate. An editor
retains the capture revision and tag/conflict snapshot it opened until save.

Delivery automatically coalesces local changes, foreground/reopen and connectivity
return. While active, bounded polling receives other-device changes without user
action. Offline is ordinary; there is no guaranteed suspended/background delivery.
The library keeps routine delivery, offline use and retries quiet. A dismissible
one-time explanation identifies the default local-only build; Device sync settings
keeps that limitation visible. Persistent connection failures, rejected work and
note conflicts provide attention notices. Details describe local availability and
do not infer device acceptance from an empty queue. See
`docs/designs/automatic-sync.md` for retry/cancellation limits and
`docs/designs/automatic-sync-ui.md` for the presentation boundary.

The default sync adapter is unconfigured. A DEBUG simulator launch can opt into the
synthetic reference transport using `--capd-synthetic-sync --capd-reference-port PORT`.
It connects only to 127.0.0.1 and has no authentication. Custom is the accepted
engine direction; this backend remains a synthetic reference. Physical-device and release builds do not enable it through
these flags. The separate portable HTTP boundary validates authenticated
service/library/device identities and durable enrollment, as described in
`docs/designs/production-sync.md`. Device sync settings prepares a retained backup
and connects an explicitly authorized HTTPS library after verifying the reviewed
import receipt or an archive-only choice. App and share sessions select the same
bound database; the share extension stays local-only. Credentials enter Keychain
only after verified activation. See [mobile library activation](../docs/designs/mobile-library-activation.md).
No credentials or development team are included in this repository.

Open `CapdPhone.xcodeproj` in Xcode. `project.yml` is the XcodeGen source. Regenerate
with `xcodegen generate --spec iOS/project.yml`. iPhone targets iOS 17 or later;
simulator signing is ad hoc (`CODE_SIGN_IDENTITY=-`) for App Group testing.

The iPhone app icon reuses `Assets/icon.svg`, the Mac icon's source artwork.
`App/AppIcon.icon` gives the white glyph native Liquid Glass depth on the original
charcoal background for iOS 26 and 27. Open it in Icon Composer to adjust material
and appearance settings. The asset catalog retains a flat 1024px icon for older
systems. Run `Scripts/make-iphone-icon.sh` (requires `rsvg-convert`) to regenerate
both the flat icon and the layered foreground vector from the Mac artwork.

Use a fresh disposable simulator/library. This prototype refuses databases containing
the old `pendingCaptures` table rather than silently creating a competing queue or
migrating old user data. Its shared projection schema migrations were exercised only
on synthetic fixtures. The Mac app's existing live Store migrations are unchanged.

Portable checks:

```sh
swift test --disable-sandbox --package-path Packages/CapdMobile --jobs 6
swift test --disable-sandbox --package-path Packages/CapdSync --jobs 6
```

`SyncIntegrationUITests` drives the actual app, a separate loopback authority, and a
separate portable Mac fixture process. It requires `CAPD_REFERENCE_PORT` and
`CAPD_MAC_FIXTURE_PORT` in its test-run environment; it explicitly skips when absent.
The reference executable is built with:

```sh
swift build --package-path Packages/CapdSync --product capd-sync-reference --jobs 6
```

Start `capd-sync-reference --authority --synthetic-root TEMP/authority --port-file TEMP/authority-port`,
then `capd-sync-reference --mac-client --authority-port PORT --synthetic-root TEMP/mac --port-file TEMP/mac-port`.
Both listeners choose fresh ephemeral loopback ports. Preserve their databases and the
simulator App Group together across a retry, since device sequences are durable.

Build for testing, install `CapdPhoneFixtureHost.app` on the owned simulator, and run
with the two scheme variables set. `-collect-test-diagnostics never` avoids verbose
system diagnostics while retaining the test's explicit screenshot attachments.

```sh
xcodebuild -project iOS/CapdPhone.xcodeproj -scheme CapdPhone \
  -derivedDataPath .build/iphone-sync -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CAPD_REFERENCE_PORT=AUTHORITY_PORT CAPD_MAC_FIXTURE_PORT=MAC_PORT \
  CODE_SIGN_IDENTITY=- test
```

The ordinary capture/share UI tests use the unconfigured adapter and synthetic data.
The external share case invokes the actual extension with the main app terminated.
`QuietUXUITests` covers quiet capture/reopen, truthful settings and the closed-app
share presentation. Its persistent-attention case requires the explicit owned
`CAPD_REFERENCE_PORT`; the unconfigured presentation cases need no server.
The process integration covers capture/reconnect, a server socket closed after commit,
exact retry, own feed echo, independent remote body/tag arrival under a pending local
note, preserved note variants, explicit resolution and deletion propagation.
The portable Mac peer is `SyncClient`, not the production Mac UI or legacy Store.

See [the design](../docs/designs/iphone-client.md) and
[the shared protocol](../docs/designs/synthetic-offline-sync.md) for limits.

The app and share extension use `CapdDesignSystem` for the Mac-derived charcoal/blue palette, typography roles, source tiles and tag styling. The iPhone follows system light/dark appearance and Dynamic Type; the Mac keeps its existing fixed dark palette and sizes. [Styling architecture](../docs/designs/iphone-styling.md) describes the shared-code boundary.
