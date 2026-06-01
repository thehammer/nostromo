#!/usr/bin/env bash
# build-icon.sh — rasterize nostromo-icon.svg into a macOS AppIcon.
#
# Produces:
#   build/AppIcon.iconset/   — the size-named PNG set
#   build/AppIcon.icns       — standalone .icns (CFBundleIconFile / standalone use)
#   AppIcon.appiconset/      — Xcode asset-catalog set (drop into Assets.xcassets)
#
# Requires: rsvg-convert (brew install librsvg) and iconutil (ships with macOS).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SVG="$HERE/nostromo-icon.svg"
BUILD="$HERE/build"
ICONSET="$BUILD/AppIcon.iconset"
ICNS="$BUILD/AppIcon.icns"
APPICONSET="$HERE/AppIcon.appiconset"

command -v rsvg-convert >/dev/null 2>&1 || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
command -v iconutil    >/dev/null 2>&1 || { echo "error: iconutil not found (macOS only)" >&2; exit 1; }
[ -f "$SVG" ] || { echo "error: missing $SVG" >&2; exit 1; }

render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2"; }   # render <px> <out.png>

rm -rf "$ICONSET" "$APPICONSET"
mkdir -p "$ICONSET" "$APPICONSET"

# --- .icns iconset (Apple's required name scheme) ---
for s in 16 32 128 256 512; do
    render "$s"       "$ICONSET/icon_${s}x${s}.png"
    render "$((s*2))" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$ICNS"
echo "→ $ICNS"

# --- Xcode asset catalog (mac AppIcon: 16/32/128/256/512 at 1x and 2x) ---
for px in 16 32 64 128 256 512 1024; do
    render "$px" "$APPICONSET/icon_${px}.png"
done
cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "size":"16x16",   "idiom":"mac", "scale":"1x", "filename":"icon_16.png"   },
    { "size":"16x16",   "idiom":"mac", "scale":"2x", "filename":"icon_32.png"   },
    { "size":"32x32",   "idiom":"mac", "scale":"1x", "filename":"icon_32.png"   },
    { "size":"32x32",   "idiom":"mac", "scale":"2x", "filename":"icon_64.png"   },
    { "size":"128x128", "idiom":"mac", "scale":"1x", "filename":"icon_128.png"  },
    { "size":"128x128", "idiom":"mac", "scale":"2x", "filename":"icon_256.png"  },
    { "size":"256x256", "idiom":"mac", "scale":"1x", "filename":"icon_256.png"  },
    { "size":"256x256", "idiom":"mac", "scale":"2x", "filename":"icon_512.png"  },
    { "size":"512x512", "idiom":"mac", "scale":"1x", "filename":"icon_512.png"  },
    { "size":"512x512", "idiom":"mac", "scale":"2x", "filename":"icon_1024.png" }
  ],
  "info" : { "author":"xcode", "version":1 }
}
JSON
echo "→ $APPICONSET (drop into macOS/Nostromo/Assets.xcassets)"
echo "done."
