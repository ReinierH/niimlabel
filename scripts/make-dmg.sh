#!/bin/zsh
# Builds the Release app and packages it as dist/NiimLabel-<version>.dmg.
set -e
cd "$(dirname "$0")/.."
scripts/build-release.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/NiimLabel.app/Contents/Info.plist)
STAGING=$(mktemp -d)
cp -R dist/NiimLabel.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="dist/NiimLabel-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "NiimLabel $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
shasum -a 256 "$DMG"
