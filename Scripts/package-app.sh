#!/bin/sh
# Builds a universal capd.app bundle and .dmg into dist/.
#
# CODESIGN_IDENTITY selects the Developer ID signing identity. Unset means
# ad-hoc, which is enough to run the bundle locally but won't pass Gatekeeper.

set -eu

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/CapdKit/CapdKit.swift)
test -n "$VERSION" || { echo "error: could not read version from CapdKit.swift" >&2; exit 1; }
SOURCE_REVISION=${CAPD_SOURCE_REVISION:-$(git rev-parse HEAD 2>/dev/null || true)}
test "${#SOURCE_REVISION}" -eq 40 || {
    echo "error: set CAPD_SOURCE_REVISION to the full source commit when packaging outside a git checkout" >&2
    exit 1
}

ARCHS=${CAPD_ARCHS:-"arm64 x86_64"}
set --
for arch in $ARCHS; do
    set -- "$@" --arch "$arch"
done
EXPECTED_ARCHS=$ARCHS

IDENTITY="${CODESIGN_IDENTITY:--}"
# Ad-hoc signatures cannot carry a secure timestamp, and notarization requires one.
if [ "$IDENTITY" = "-" ]; then
    TIMESTAMP=--timestamp=none
else
    TIMESTAMP=--timestamp
fi

swift package resolve --build-system swiftbuild --force-resolved-versions
swift build --build-system swiftbuild --disable-automatic-resolution -c release "$@"

BIN=$(swift build --build-system swiftbuild --disable-automatic-resolution \
    -c release "$@" --show-bin-path)
APP=dist/capd.app

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

sed -e "s/CAPD_VERSION/$VERSION/g" \
    -e "s/CAPD_SOURCE_REVISION/$SOURCE_REVISION/g" \
    Scripts/Info.plist > "$APP/Contents/Info.plist"
cp Assets/capd.icns "$APP/Contents/Resources/"

# capd and capd-agent ship next to the app executable: AgentBootstrap and
# `capd doctor` both resolve them relative to their own binary, and the
# Homebrew cask symlinks the CLI from here into PATH.
cp "$BIN/CapdApp" "$BIN/capd" "$BIN/capd-agent" "$APP/Contents/MacOS/"

APPEX="$APP/Contents/PlugIns/CapdShareExtension.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
sed "s/CAPD_VERSION/$VERSION/g" Scripts/ShareExtension-Info.plist > "$APPEX/Contents/Info.plist"
cp Assets/capd.icns "$APPEX/Contents/Resources/"
cp "$BIN/CapdShareExtension" "$APPEX/Contents/MacOS/"
# Dependency resource bundles (GRDB, KeyboardShortcuts) ship too, but a stale
# build dir can also hold test-target bundles, which must not.
for bundle in "$BIN"/*.bundle; do
    case "$bundle" in *Tests.bundle) continue ;; esac
    cp -R "$bundle" "$APP/Contents/Resources/"
done

for binary in "$APP/Contents/MacOS/CapdApp" "$APP/Contents/MacOS/capd" \
    "$APP/Contents/MacOS/capd-agent" "$APPEX/Contents/MacOS/CapdShareExtension"; do
    for arch in $EXPECTED_ARCHS; do
        lipo "$binary" -verify_arch "$arch" || {
            echo "error: $(basename "$binary") is missing $arch" >&2
            exit 1
        }
    done
    lipo -info "$binary"
done

codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" \
    "$APP/Contents/MacOS/capd" "$APP/Contents/MacOS/capd-agent"
# Nested code signs inside-out: the appex's seal is part of the app's.
codesign --force --options runtime "$TIMESTAMP" \
    --entitlements Scripts/capd-share.entitlements --sign "$IDENTITY" "$APPEX"
codesign --force --options runtime "$TIMESTAMP" \
    --entitlements Scripts/capd.entitlements --sign "$IDENTITY" "$APP"

codesign --verify --strict --deep "$APP"

if [ "${CAPD_SKIP_DMG:-0}" = 1 ]; then
    echo "packaged $APP"
    exit 0
fi

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# SetFile ships with the full Xcode CLT; the volume icon is cosmetic, so its
# absence must not fail packaging.
cp Assets/capd.icns "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING" 2>/dev/null || true
# hdiutil intermittently fails with "Resource busy" on CI runners.
for attempt in 1 2 3; do
    if hdiutil create -volname capd -srcfolder "$STAGING" -ov -format UDZO \
        "dist/capd-$VERSION.dmg"; then
        break
    fi
    test "$attempt" -lt 3 || exit 1
    sleep 5
done
rm -rf "$STAGING"

# Gatekeeper's dmg assessment (spctl -t open) requires a signature on the
# image itself; notarizing and stapling it is not enough.
codesign --force "$TIMESTAMP" --sign "$IDENTITY" "dist/capd-$VERSION.dmg"

echo "packaged dist/capd-$VERSION.dmg"
