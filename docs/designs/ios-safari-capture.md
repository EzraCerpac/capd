# Safari current-page capture

`CapdPhoneSafari` is an embedded iOS Safari web extension. The containing app,
share extension and Safari extension target iOS 17 or later. Its popup is the
only JavaScript entry point. Invoking it reads the active tab's URL/title with
`activeTab`; opening or closing it never writes a capture. The user reviews the
URL, edits the title and optional note, then explicitly chooses Save.

The popup sends `capd.capture-link.v1` with exactly four string fields: command,
URL, title and note. Limits are 16 KiB for the URL, 4 KiB for the title and 16 KiB
for the note, measured in UTF-8 on both sides. The native handler rejects unknown
commands, fields, types, missing values and unsupported URLs. `CaptureInput`
provides the shared HTTP(S), nonempty-host and embedded-credential validation.
Page-supplied text enters form values, never HTML. The handler returns only
`saved` or `error`; it exposes no library reads, credentials or diagnostic paths.

Saving calls `MobileEnvironment.session(role: .shareExtension).save`. That role
uses `LocalOnlySyncAdapter`, never reads Keychain credentials, and uses the same
database selector, cross-process lease, transactional projection and durable
outbox as the existing app/share flow. A changed library session remains fenced.
The foreground app delivers pending work through its existing enrolled adapter.
The extension makes no direct service request and cannot establish enrollment.
Local success is described as saved to this device, not server acceptance.

The manifest declares only `activeTab` and `nativeMessaging`, with no persistent
host access, content scripts, background execution, storage, cookies, history,
external messaging or page resource requests. Its content policy restricts
scripts/styles to bundled files and disables network connections. There is no
automatic capture, upload, retry or browsing collection. Concurrent submissions
are suppressed and successful Save disables further submission in that popup.
If a reply is lost, the draft remains and the user is told to check capd before
trying again; transport failure does not prove the local transaction failed.

Extension and toolbar PNG sizes derive from the existing Capd SVG. Their folder
resource preserves standard PNG bytes instead of iOS-specific image optimization.

The new bundle needs its own provisioning profile and approval to join the
existing `group.dev.jxd.capd.iphone.prototype` App Group. No new Keychain group or
service credential is needed. It reuses `Shared/CapdPhone.entitlements`; the
association and profile require separate authorization before provisioning. Do not install an
update that omits the approved shared-container entitlement or replaces the
existing app identity. Existing app and share entitlements are unchanged.

## Verification

`SafariCaptureRequestTests` checks allowed fields, URL policy, UTF-8 limits, local
persistence and the existing outbox. The enrolled activation test saves a Safari
request through a credential-failing share session, checks selected-library
identity, and delivers it through the existing authenticated synthetic adapter.
`iOS/SafariTests/CapturePopupTests.mjs` checks that preview sends nothing, Save
sends reviewed fields once, unsupported/denied pages send nothing, and failures
retain the draft without automatic retries. It also checks manifest permissions.

These tests and compilation do not establish Safari's real permission prompt,
native-messaging delivery, extension enablement or physical-device installation.
Check those separately on an owned simulator/device using a synthetic HTTP(S)
page, with the main app closed while saving. Then reopen capd and verify the link,
edited title and note. If enrolled, observe normal outbox delivery separately.
Also check cancel, denied access, non-web pages, oversized fields, offline Save,
light/dark appearance, large text and iPad layout. Keep existing app data and
selected-library configuration intact during any in-place device update.

Apple's [native messaging guide](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension),
[permission model](https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions),
and [running guide](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)
describe the platform behavior and enablement steps.
