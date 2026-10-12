#!/bin/zsh
# Builds a Release NiimLabel.app into ./dist (ad-hoc signed, for local use).
set -e
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project NiimLabel.xcodeproj -scheme NiimLabel -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build | grep -E "error:|BUILD"
mkdir -p dist
rm -rf dist/NiimLabel.app
cp -R build/DerivedData/Build/Products/Release/NiimLabel.app dist/
echo "→ dist/NiimLabel.app"
