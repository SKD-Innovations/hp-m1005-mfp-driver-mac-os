#!/bin/sh
set -eu

if [ -z "${DEVELOPER_ID_APPLICATION:-}" ] || \
   [ -z "${DEVELOPER_ID_INSTALLER:-}" ] || \
   [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "Set DEVELOPER_ID_APPLICATION, DEVELOPER_ID_INSTALLER, and NOTARY_PROFILE." >&2
    exit 2
fi

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_directory="$project_directory/build/release"
source_app="$project_directory/build/M1005Printer.app"
release_app="$release_directory/M1005Printer.app"
release_package="$release_directory/HP-LaserJet-M1005-0.5.2.pkg"
entitlements="$project_directory/macos/entitlements.plist"

cd "$project_directory"
make phase5

rm -rf "$release_directory"
mkdir -p "$release_directory"
COPYFILE_DISABLE=1 ditto "$source_app" "$release_app"
xattr -cr "$release_app"

codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$release_app/Contents/Resources/m1005-xqx-encode"
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$release_app/Contents/Resources/m1005-printer-service"
codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" "$release_app"
codesign --verify --deep --strict --verbose=2 "$release_app"

COPYFILE_DISABLE=1 pkgbuild --component "$release_app" \
    --install-location /Applications \
    --identifier com.m1005printer.pkg --version 0.5.2 \
    --sign "$DEVELOPER_ID_INSTALLER" "$release_package"

xcrun notarytool submit "$release_package" \
    --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$release_package"
xcrun stapler validate "$release_package"
spctl --assess --type install --verbose=2 "$release_package"

echo "Signed and notarized installer: $release_package"
