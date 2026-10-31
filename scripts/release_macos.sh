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
app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$project_directory/macos/Info.plist")
app_name="M1005Printerv${app_version#0.}"
release_app="$release_directory/$app_name.app"
release_package="$release_directory/HP-LaserJet-M1005-$app_version.pkg"
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

mkdir -p "$release_directory/payload"
COPYFILE_DISABLE=1 ditto "$release_app" "$release_directory/payload/$app_name.app"
sed "s/@APP_NAME@/$app_name/g" macos/package-components.plist > "$release_directory/components.plist"
COPYFILE_DISABLE=1 pkgbuild --root "$release_directory/payload" \
    --component-plist "$release_directory/components.plist" \
    --install-location /Applications \
    --identifier com.m1005printer.pkg --version "$app_version" \
    --sign "$DEVELOPER_ID_INSTALLER" "$release_package"

xcrun notarytool submit "$release_package" \
    --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$release_package"
xcrun stapler validate "$release_package"
spctl --assess --type install --verbose=2 "$release_package"

echo "Signed and notarized installer: $release_package"
