#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
    echo "error: rsvg-convert not found (brew install librsvg)" >&2
    exit 1
}

CAPD_ICON_SCRATCH=$(mktemp -d)
trap 'rm -rf "$CAPD_ICON_SCRATCH"' EXIT HUP INT TERM
CAPD_ICON_OUTPUT=iOS/SafariExtension/Resources

# Safari tints the toolbar image's alpha; omit the app tile behind the glyph.
python3 - "$CAPD_ICON_SCRATCH/toolbar.svg" <<'PY'
import sys
import xml.etree.ElementTree as ET

paths = ET.parse("Assets/icon.svg").findall(".//{http://www.w3.org/2000/svg}path")
assert len(paths) == 1
svg = ET.Element("svg", xmlns="http://www.w3.org/2000/svg", viewBox="-5 -5 110 110")
ET.SubElement(svg, "path", d=paths[0].attrib["d"], fill="black")
ET.ElementTree(svg).write(sys.argv[1])
PY

for size in 48 64 96 128 256 512; do
    rsvg-convert -w "$size" -h "$size" Assets/icon.svg \
        -o "$CAPD_ICON_OUTPUT/icon-$size.png"
done
for size in 16 19 32 38; do
    rsvg-convert -w "$size" -h "$size" "$CAPD_ICON_SCRATCH/toolbar.svg" \
        -o "$CAPD_ICON_OUTPUT/toolbar-$size.png"
done
echo "regenerated Safari PNG icons from Assets/icon.svg"
