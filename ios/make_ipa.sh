#!/bin/sh
# Builds an UNSIGNED .ipa (ios/build/OpenUG2-unsigned.ipa) for sideloading tools -- AltStore, SideStore,
# Sideloadly -- which sign it with your own Apple ID, so no Xcode run is needed on each refresh.
# Run ./build_deps.sh first (device libraries), and `xcodegen generate` once.
set -eu
cd "$(dirname "$0")"
[ -d OpenUG2.xcodeproj ] || xcodegen generate
xcodebuild -project OpenUG2.xcodeproj -scheme OpenUG2 -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP=build/Build/Products/Release-iphoneos/OpenUG2.app
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }
rm -rf build/ipa build/OpenUG2-unsigned.ipa
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
( cd build/ipa && zip -qry ../OpenUG2-unsigned.ipa Payload )
echo "wrote $(pwd)/build/OpenUG2-unsigned.ipa"
