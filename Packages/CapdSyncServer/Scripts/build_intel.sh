#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$repo_dir"
xcrun swift build --build-system native --package-path Packages/CapdSyncServer \
    --configuration release --triple x86_64-apple-macosx15.0
artifact_dir="$repo_dir/.build/artifacts/capd-sync-server-macos-intel"
mkdir -p "$artifact_dir"
cp Packages/CapdSyncServer/.build/x86_64-apple-macosx/release/capd-sync-server "$artifact_dir/capd-sync-server"
# Xcode's back-deployment shim is needed by this compiler; do not depend on Xcode on the host.
toolchain_usr=$(dirname "$(dirname "$(xcrun --find swift)")")
compatibility_dir="$toolchain_usr/lib/swift-6.2/macosx"
if otool -L "$artifact_dir/capd-sync-server" | grep -Fq '@rpath/libswiftCompatibilitySpan.dylib'; then
    xcrun lipo "$compatibility_dir/libswiftCompatibilitySpan.dylib" -thin x86_64 \
        -output "$artifact_dir/libswiftCompatibilitySpan.dylib"
    xcrun install_name_tool -id '@rpath/libswiftCompatibilitySpan.dylib' \
        "$artifact_dir/libswiftCompatibilitySpan.dylib"
    codesign --force --sign - "$artifact_dir/libswiftCompatibilitySpan.dylib"
    xcrun install_name_tool -change '@rpath/libswiftCompatibilitySpan.dylib' \
        '@loader_path/libswiftCompatibilitySpan.dylib' "$artifact_dir/capd-sync-server"
fi
if otool -l "$artifact_dir/capd-sync-server" | grep -Fq "path $compatibility_dir "; then
    xcrun install_name_tool -delete_rpath "$compatibility_dir" "$artifact_dir/capd-sync-server"
fi
codesign --force --sign - "$artifact_dir/capd-sync-server"
file "$artifact_dir/capd-sync-server"
xcrun vtool -show-build "$artifact_dir/capd-sync-server"
otool -L "$artifact_dir/capd-sync-server"
cat > "$artifact_dir/README.txt" <<'NOTE'
Capd sync server for Intel macOS 15 or newer.
Keep capd-sync-server and libswiftCompatibilitySpan.dylib together.
Run: ./capd-sync-server --config /owned/path/enrollment.json --data-dir /owned/path/fresh-sync-data --port 8080
Listener is loopback-only. HTTPS reverse proxy and secure device enrollment are required before remote use.
No default/live library directory is used. The data root must be fresh or already bound to this service.
Built with Xcode Swift 6.4; inspected x86_64/macOS 15 minimum and checked locally under Rosetta.
Execution on the NAS macOS 15.8 runtime remains unverified. See source package README for schema and limits.
NOTE
tar -czf "$repo_dir/.build/artifacts/capd-sync-server-macos-intel.tar.gz" \
    -C "$repo_dir/.build/artifacts" capd-sync-server-macos-intel
printf 'Prepared Intel bundle: %s\n' "$artifact_dir"
