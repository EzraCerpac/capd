# capd for iPhone and iPad

This fork adds a native mobile client to [Jamie Davenport's Capd](https://github.com/jamiedavenport/capd).
It saves links and text locally, searches saved sources, edits notes/manual tags,
resolves note variants, and deletes captures. The app and share extension target
iOS 17 or later and both iPhone and iPad. Ask Cap has separate iOS 26/model requirements.
See the [fork overview](../README.md) and [installation guide](../docs/content/01-install.mdx).

<p>
  <img src="../docs/public/fork/iphone-library-light.png" width="260" alt="Current mobile library with synthetic sources">
  <img src="../docs/public/fork/iphone-detail-light.png" width="260" alt="Current saved source with a synthetic note and tags">
</p>

These are actual simulator captures from the current app, with synthetic data.
[Interface examples](../docs/content/10-screenshots.mdx) include share, settings
and citation screens. The citation example retains its fixture disclaimer;
it does not show Apple-model generation or a live server connection.

## First capture and recall

1. Tap **+ (Capture)**, choose **Link** or **Text**, and enter the source. Add an
   optional title and note, then choose **Save**.
2. Or choose capd from another app's share sheet, review the URL/text and optional
   note, then save. The extension writes to the selected App Group library even
   while the main app is closed.
3. Use **Search saved sources** to find a title, URL substring, source text, note,
   manual/generated tag, saved page text, or recognized image text. Prefix and
   literal matches are combined, with newest captures first. The mobile field
   does not parse Mac `site:`, `tag:`, or date filters.
4. Open a source to review its saved content. **Edit** changes the note and manual
   tags; separate new tags with spaces and choose **Save changes**. The share
   button shares a non-image source's URL or text. **Delete source** requires
   confirmation.

The phone does not fetch webpages, perform OCR, create image captures, schedule
reminders, or edit ratings. It can display synchronized page text, recognized
image text, generated tags, and capture metadata, including a reminder date.
Manual notes remain separate from source text and generated results.

If a source has **Notes to resolve**, review its versions in **Edit**, write the
note to retain, and explicitly enable **Use this note to resolve all variants**
before saving. The editor retains its opening revision and observed variants;
a newer unseen note can require another review.

## Device connection and delivery

A library without enrollment stays on this device. To connect an existing,
authorized HTTPS library, open **Device sync → Prepare device connection**.
Enter the endpoint and service/library UUIDs. **Check private connection** sends
no credential and checks reachability only; it does not prove library identity.

**Save backup and prepare connection** retains the original database and outbox.
A nonempty library requires the reviewed host import and committed receipt, or
the explicit **Keep old sources archived; use server library** choice. **Generate
device credential** provides a verifier for separate host authorization. Only
after that authorization does **Verify and connect** validate and activate the
library. This screen does not create a server or device grant. Follow the
[sync guide](../docs/content/08-sync.mdx) for the complete workflow.

App and share sessions select the same bound database. The app uses the enrolled
HTTPS adapter; the share extension remains local-only and never reads Keychain
or sends network requests. Credentials enter Keychain only after verified
activation. No credentials or development team are included in the repository.

Captures save locally and remain available offline. When connected, the app
delivers changes automatically after local edits, reopening, and connectivity
return, and checks for other-device changes every 30 seconds while active.
There is no guaranteed delivery while iOS suspends or closes the app. The main
app delivers closed-app share saves when it becomes active.

**Device sync** shows the last completed update, connection details, rejected
changes, and notes requiring review. Routine delivery and offline retries remain
quiet. Transient failures retry with bounded backoff; persistent or nontransient
errors require attention and eventually stop automatic attempts. **Retry connection**
appears for an attention error; reopening or connectivity return also resets retry
attempts. Rejected changes retain local data, but have no mobile recovery tool.
An empty queue or **Available on this device** label does not prove acceptance
by another device. See [troubleshooting](../docs/content/09-troubleshooting.mdx).

## Website icons

**Device sync → Show synced website icons** controls display and starts enabled.
The phone reads verified local icon assets and never requests icons from saved
websites. Enable **Load website icons** on a connected Mac and keep its background
Agent available to generate icons for eligible links saved on either device.
Delivery requires server icon support. Missing, corrupt, or unavailable icons
use native symbols; icon issues do not turn accepted capture sync into failure.
Cached icons remain available offline. See [website icons](../docs/designs/website-icons.md).

## Ask Cap

Tap **Ask Cap** (the sparkles icon), enter a question, then tap **Ask Cap** in the sheet. It uses
Apple's on-device model on iOS 26 or later, subject to eligible hardware, enabled Apple Intelligence,
model readiness, and locale support. **Check again** refreshes availability.
An available model can still fail to generate an answer.

Answers include supporting quotes and open current saved-source details. Saved
sources are checked again before an answer appears. Questions and answers are
not persisted, links are not fetched, and there is no remote fallback. Citations
and matching quotes help review evidence; they do not guarantee correctness.
See [local answers](../docs/designs/iphone-local-answers.md).

## Spotlight and Shortcuts

**Device sync → Find captures in Spotlight and Shortcuts** starts off. It indexes
saved titles and manual tags, excluding bodies, OCR, source text, notes, conflicts,
and generated tags. The complete selected library is reconciled independently
of the visible filter. A closed-app share is reconciled after the app next opens.

The named actions are **Find Captures**, **Open Capture**, and **Draft Text**.
Find/Open require discovery consent. Draft Text is independent of that consent
and stages an editable form requiring Save. These actions do not provide arbitrary
Siri questions. OS discovery requires a suitable signed installation and is not
established by compilation or synthetic tests.

Indexed entries receive a 30-day expiration and renew while the app is active.
Turning discovery off requests removal; failures remain visible for retry.
Libraries over 1,000 live captures, oversized metadata, or ambiguous source-title
redaction fail closed rather than exposing a partial index. In-app search remains
available. Detailed projection budgets and routing are in
[discovery integration](../docs/designs/phone-discovery-integration.md).

## Build and architecture

Open `iOS/CapdPhone.xcodeproj` from the repository root in Xcode. `iOS/project.yml`
is the XcodeGen source; regenerate from the root with
`xcodegen generate --spec iOS/project.yml`. Simulator App Group testing uses ad hoc
signing (`CODE_SIGN_IDENTITY=-`). Physical installation requires separately
configured signing and App Group provisioning; a simulator build does not verify it.

`Packages/CapdMobile` uses the shared `CapdSync` outbox, device identity, and
sequence. Local source rows and FTS are a transactional projection of accepted
records plus pending local edits. There is no separate mobile pending queue or
set-of-IDs acknowledgement path; manual/generated tags remain separate. See
[the client design](../docs/designs/iphone-client.md) and
[mobile library activation](../docs/designs/mobile-library-activation.md).

A DEBUG simulator launch can select the synthetic reference transport with
`--capd-synthetic-sync --capd-reference-port PORT`. It connects only to 127.0.0.1
and has no authentication. Physical-device and release builds do not enable it
through these flags. It is separate from verified HTTPS enrollment and is not a
deployable service. See [the production protocol](../docs/designs/production-sync.md).

The iPhone app icon reuses [`Assets/icon.svg`](../Assets/icon.svg), the Mac icon's
source artwork. `iOS/App/AppIcon.icon` contains the layered Icon Composer artwork
for Liquid Glass appearance on supported systems. Open it in Icon Composer to
adjust material and appearance settings. The asset catalog retains a flat 1024px icon for older
systems. Run `Scripts/make-iphone-icon.sh` (requires `rsvg-convert`) to regenerate
both the flat icon and the layered foreground vector from the Mac artwork.

## Fixture checks and verification limits

Use a fresh disposable simulator/library. The client refuses databases containing
the old `pendingCaptures` table rather than silently creating a competing queue or
migrating old user data. Fixture migration checks use synthetic libraries and do
not establish a migration of that legacy user queue. Mac Store migrations have
their own schema and enrollment requirements.

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

These fixture checks do not establish the current deployed service, installed
physical-device behavior, signed OS discovery, or native model answer quality.

The app and share extension use `CapdDesignSystem` for the Mac-derived
charcoal/blue palette, typography roles, source tiles, and tag styling. Mobile
views follow system light/dark appearance and Dynamic Type; the Mac keeps its
fixed dark palette and sizes. [Styling architecture](../docs/designs/iphone-styling.md)
describes the shared-code boundary. The shared artwork and MIT/third-party
notices retain the upstream project's credit.
