#!/bin/bash
# Build dist/Ext4-Automount-<version>.pkg.  Usage: packaging/build-pkg.sh [version]
#
# Optional signing (needs an Apple Developer account); unset = ad-hoc signed:
#   APP_SIGN_ID        "Developer ID Application: Name (TEAMID)"
#   INSTALLER_SIGN_ID  "Developer ID Installer: Name (TEAMID)"
#   NOTARY_PROFILE     keychain profile from `xcrun notarytool store-credentials`
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-1.0.0}
ID=local.ext4-automount
SUPPORT="Library/Application Support/Ext4 Automount"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
root=$work/root
app="$root/Applications/Ext4 Automount.app"
pkg="dist/Ext4-Automount-$VERSION.pkg"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$root/Library/LaunchDaemons" \
         "$root/Library/LaunchAgents" "$root/$SUPPORT" "$root/private/etc/newsyslog.d" dist

# Universal binary
for arch in arm64 x86_64; do
  swiftc -O -module-name Ext4Automount -target "$arch-apple-macos11" src/*.swift -o "$work/bin-$arch"
done
lipo -create "$work/bin-arm64" "$work/bin-x86_64" -output "$app/Contents/MacOS/ext4-automount"

sed "s/VERSION/$VERSION/g" src/Info.plist > "$app/Contents/Info.plist"
install -m 755 src/uninstall.sh "$app/Contents/Resources/uninstall.sh"
install -m 644 packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"   # from make-icon.sh
install -m 644 packaging/files/$ID.plist      "$root/Library/LaunchDaemons/"
install -m 644 packaging/files/$ID.menu.plist "$root/Library/LaunchAgents/"
install -m 644 packaging/files/config.example "$root/$SUPPORT/"
install -m 644 packaging/files/newsyslog.conf "$root/private/etc/newsyslog.d/ext4-automount.conf"

if [ -n "${APP_SIGN_ID:-}" ]; then
  codesign -s "$APP_SIGN_ID" --options runtime --timestamp -f "$app"
else
  codesign -s - -f "$app"
fi
chmod 755 packaging/scripts/*

# Install exactly at /Applications; don't "relocate" to another copy of the app.
pkgbuild --analyze --root "$root" "$work/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false "$work/components.plist"

COPYFILE_DISABLE=1 pkgbuild --root "$root" --component-plist "$work/components.plist" \
  --scripts packaging/scripts --identifier "$ID" --version "$VERSION" \
  --ownership recommended "$work/component.pkg"

# Wrap it in a product package so the Installer window shows the name and logo.
productbuild --synthesize --package "$work/component.pkg" "$work/distribution.xml"
sed -i '' 's|<installer-gui-script minSpecVersion="1">|&\
    <title>Ext4 Automount</title>\
    <background file="installer-background.png" mime-type="image/png" alignment="bottomleft" scaling="none"/>\
    <background-darkAqua file="installer-background.png" mime-type="image/png" alignment="bottomleft" scaling="none"/>|' \
  "$work/distribution.xml"
mkdir "$work/resources"
cp packaging/installer-background.png "$work/resources/"
productbuild --distribution "$work/distribution.xml" --package-path "$work" --resources "$work/resources" \
  ${INSTALLER_SIGN_ID:+--sign "$INSTALLER_SIGN_ID"} "$pkg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$pkg"
fi
echo "Built $pkg"
