# Contributing to this Capd fork

This repository extends [Jamie Davenport's Capd](https://github.com/jamiedavenport/capd)
with shared-library sync, an iPhone/iPad client, and related integrations. Bug
fixes, documentation, and focused improvements are welcome. Preserve the upstream
credit and MIT license.

## Requirements

- macOS 26 or later for the Mac app
- Xcode 26.4.1 for the current Mac/iOS build and package checks, matching build CI
- Swift tools 6.2 or later
- XcodeGen when regenerating the iOS project
- Node.js 24 when working on the documentation site

CI's Swift formatter remains pinned to Xcode 26.3. Use that formatter when
preparing Swift changes. The newer build SDK is needed by the shared on-device
answer package's Foundation Models token-budget APIs.

Apple Intelligence is optional for capture and search. Automatic tags and local
answers require an eligible device, an enabled and ready model, and a supported
language. The iOS app targets iOS 17 or later; Ask Cap requires iOS 26 or later.

## Set up a checkout

```sh
git clone https://github.com/EzraCerpac/capd.git
cd capd
./Scripts/bootstrap.sh
swift build
```

`bootstrap.sh` resolves root Swift dependencies and sets this clone's
`core.hooksPath` to `.githooks`. The pre-commit hook formats staged Swift files,
skipping files with unstaged changes. It does not install Capd or configure sync.

## Build the Mac app bundle

From the repository root:

```sh
Scripts/package-app.sh
```

The script replaces `dist/` and produces a universal `dist/capd.app` and
`dist/capd-<version>.dmg`. The bundle includes the app, `capd` CLI, `capd-agent`,
share extension, and dependency resources. A plain `swift build` produces
executables rather than this complete installation bundle.

Local packaging uses an ad hoc signature by default. `CODESIGN_IDENTITY` selects
a real signing identity, but this script does not notarize a build. Signing and
notarization in the release workflow are separate steps requiring the operator's
own credentials.

Follow the [installation guide](docs/content/01-install.mdx) to install the
bundle. The fork retains upstream's app/helper identifiers and default library
location. Launching the app installs or repairs the helper; do not launch a
development build against a live library as an isolation technique. Use
disposable libraries and matching app, agent, and CLI binaries for integration
work. Setting `CAPD_DIR` in one shell does not configure every other writer.

## Build the iOS app

`iOS/project.yml` is the XcodeGen source. Regenerate from the repository root:

```sh
xcodegen generate --spec iOS/project.yml
```

Open `iOS/CapdPhone.xcodeproj` and select the `CapdPhone` scheme. CI compiles the
app and share extension without installing or launching them:

```sh
xcodebuild -project iOS/CapdPhone.xcodeproj -scheme CapdPhone \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/iphone-compile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The repository supplies no development team, provisioning profile, or physical
device signing setup. App and share extension must retain their matching App
Group configuration. Simulator integration tests use ad hoc signing and
explicitly selected disposable fixtures; an unsigned compilation does not
exercise that entitlement or prove device connectivity. See [iOS/README.md](iOS/README.md).

## Server and administration packages

Build these separately from the Mac app:

```sh
swift build --build-system native --package-path Packages/CapdSyncServer \
  --product capd-sync-server
swift build --package-path Packages/CapdSyncAdmin -c release
```

The server listens on loopback and needs separately configured HTTPS routing for
remote devices. Building it does not deploy a service or enroll a library. The
admin executable previews/imports copied content into an existing bound
authority. See the [connection guide](docs/content/08-sync.mdx),
[server package](Packages/CapdSyncServer/README.md), and
[administration package](Packages/CapdSyncAdmin/README.md).

## Project layout

- `Sources/CapdKit`: Mac model, store, capture pipeline, search, and sync runtime
- `Sources/CapdCLI`, `CapdAgent`, and `CapdApp`: CLI, enrichment worker, and menu-bar app
- `Sources/CapdAppUI`: Mac views and presentation models
- `Sources/CapdShareExtension` and `CapdHandoff`: Mac share extension and relay
- `Packages/CapdSync`, `CapdSyncServer`, and `CapdSyncAdmin`: protocol, host, and offline administration
- `Packages/CapdMobile` and `iOS/`: mobile store, app, and share extension
- Other `Packages/`: shared design, icons, answers, system integration, and MCP support
- `docs/content`: user guides; `docs/designs`: technical contracts and boundaries

## Before opening a pull request

Format Swift with CI's formatter toolchain, then run checks appropriate to your
change. The root checks are:

```sh
swift format --in-place --recursive Sources Tests Package.swift
swift format lint --strict --recursive --parallel Sources Tests Package.swift
swift test --parallel
```

CI also formats package and iOS source directories and tests portable packages.
For a changed package, use its own manifest, for example:

```sh
swift test --package-path Packages/CapdSync --jobs 4 --no-parallel
swift test --package-path Packages/CapdMobile --jobs 4 --no-parallel
```

Keep tests on disposable synthetic data. Opt-in simulator/process tests have
additional fixture requirements documented beside their packages. Their results
do not establish live NAS deployment, physical-device enrollment, or migration
of private libraries.

Use a [Conventional Commit](https://www.conventionalcommits.org/) message and
describe the final behavior and relevant validation in the pull request. The
CLI's JSON fields and exit codes are stable interfaces; update corresponding
golden tests for intentional changes.

## Documentation

Customer documentation uses Blume. With Node.js 24, from `docs/`:

```sh
npm ci
npm run doctor
npm run build -- --strict
```

Write about implemented behavior in plain language. Preserve command, path,
bundle, service, and setting names. Link technical details to `docs/designs/`.
Do not turn synthetic tests or source compilation into claims about real
deployment. [CLAUDE.md](CLAUDE.md) is the shared project policy; [AGENTS.md](AGENTS.md)
points to it.

## Distribution and release configuration

The checked-in release workflow runs on `v*` tags matching `CapdKit.version`,
packages the Mac app, and includes signing, notarization, GitHub release, and
Homebrew publication steps. Its tap/cask URLs still target
`jamiedavenport/homebrew-tap` and upstream Capd. The app's weekly update checker
also targets upstream releases.

Those files describe the inherited workflow, not an established fork release
channel. A fork distribution needs its own reviewed release configuration and
signing credentials. The source instructions above do not require a fork
notarized release or install from the upstream tap.
