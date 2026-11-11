#!/bin/bash
# Regenerate packaging/AppIcon.icns from packaging/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
swift make-icon.swift "$tmp/icon.png"
mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o AppIcon.icns
sips -z 256 256 "$tmp/icon.png" --out icon-preview.png >/dev/null   # for the README
# Installer window background: the logo with some margin, bottom-left.
sips -z 150 150 "$tmp/icon.png" --out installer-background.png >/dev/null
sips -p 190 190 installer-background.png >/dev/null
echo "Wrote packaging/AppIcon.icns"
