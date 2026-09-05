#!/usr/bin/env bash
#
# Builds a Release copy of AirRefresh and zips it into dist/.
#
#   ./Scripts/build-release.sh
#
# The result is ad-hoc signed, which is enough to run but not enough for
# Gatekeeper to stay quiet on someone else's Mac — see "Installing" in the
# README for what your users will have to do.
#
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="build"
DIST_DIR="dist"
VERSION="$(xcodebuild -project AirRefresh.xcodeproj -scheme AirRefresh -configuration Release \
             -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
VERSION="${VERSION:-0.0.0}"

echo "▸ Building AirRefresh $VERSION"
rm -rf "$BUILD_DIR"
xcodebuild build \
  -project AirRefresh.xcodeproj \
  -scheme AirRefresh \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  | grep -E '^(\*\*|error:|warning:)' || true

APP="$BUILD_DIR/DerivedData/Build/Products/Release/AirRefresh.app"
[ -d "$APP" ] || { echo "✗ No app at $APP"; exit 1; }

mkdir -p "$DIST_DIR"
cp -R "$APP" "$BUILD_DIR/AirRefresh.app"

ZIP="$DIST_DIR/AirRefresh-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$BUILD_DIR/AirRefresh.app" "$ZIP"

echo "✓ $ZIP"
echo "  $(du -h "$ZIP" | cut -f1)"
