#!/bin/sh
# Derive the iPhone app icon from the same SVG as the Mac icon.
# Requires librsvg (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
    echo "error: rsvg-convert not found (brew install librsvg)" >&2
    exit 1
}

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
ICON=iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
GLYPH=iOS/App/AppIcon.icon/Assets/capd-glyph.svg

# Crop away the Mac canvas margin, retain its glyph proportions, and fill the
# square tile. iOS supplies the corner mask, so omit the Mac rounding and border.
sed -e 's|viewBox="0 0 1024 1024"|viewBox="100 100 824 824"|' \
    -e 's| rx="185"||' \
    -e '/<rect .*stroke=/d' Assets/icon.svg >"$TEMP_DIR/icon.svg"
mkdir -p "$(dirname "$ICON")"
rsvg-convert -w 1024 -h 1024 "$TEMP_DIR/icon.svg" -o "$ICON"
# Icon Composer adds the glass, lighting, and shadow from icon.json. Keep its
# foreground vector synchronized with the Mac artwork, without baked-in effects.
mkdir -p "$(dirname "$GLYPH")"
sed -e 's|viewBox="0 0 1024 1024"|viewBox="100 100 824 824"|' \
    -e '/<rect /d' Assets/icon.svg >"$GLYPH"
echo "regenerated $ICON from Assets/icon.svg"
echo "regenerated $GLYPH from Assets/icon.svg"
