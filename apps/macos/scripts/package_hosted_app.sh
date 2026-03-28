#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$ROOT_DIR/apps/macos"
DIST_DIR="${REMOTEOS_DIST_DIR:-$ROOT_DIR/dist/macos-hosted}"
DERIVED_DATA_PATH="${REMOTEOS_DERIVED_DATA_PATH:-$ROOT_DIR/DerivedData/remoteos-macos-hosted}"

APP_NAME="${REMOTEOS_APP_NAME:-RemoteOS}"
BUNDLE_IDENTIFIER="${REMOTEOS_BUNDLE_IDENTIFIER:-dev.remoteos.hosted}"
VERSION="${REMOTEOS_VERSION:-0.1.0}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${REMOTEOS_BUILD_NUMBER:-$(date '+%Y%m%d%H%M')}"
BASE_URL="${REMOTEOS_CONTROL_PLANE_BASE_URL:-}"
HOST_MODE="${REMOTEOS_HOST_MODE:-hosted}"
MINIMUM_MACOS_VERSION="${REMOTEOS_MINIMUM_MACOS_VERSION:-14.0}"
ARCHS="${REMOTEOS_ARCHS:-}"
ICON_FILE="${REMOTEOS_ICON_FILE:-}"

SIGNING_IDENTITY="${REMOTEOS_SIGNING_IDENTITY:-}"
AUTO_DETECTED_SIGNING_IDENTITY=0
NOTARY_PROFILE="${REMOTEOS_NOTARY_PROFILE:-}"
APPLE_ID="${REMOTEOS_NOTARY_APPLE_ID:-${APPLE_ID:-}}"
APPLE_PASSWORD="${REMOTEOS_NOTARY_APPLE_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}"
APPLE_TEAM_ID="${REMOTEOS_NOTARY_TEAM_ID:-${APPLE_TEAM_ID:-}}"

APP_ROOT="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS.txt"

function require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

function detect_signing_identity() {
    typeset -a identities preferred_fragments
    local line=""
    local identity_name=""

    identities=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null)}")
    preferred_fragments=(
        "RemoteOS Local Code Signing"
        "Developer ID Application:"
        "Apple Development:"
    )

    for fragment in "${preferred_fragments[@]}"; do
        for line in "${identities[@]}"; do
            [[ "$line" == *\"* ]] || continue
            identity_name="${line#*\"}"
            identity_name="${identity_name%%\"*}"
            if [[ -n "$identity_name" && "$identity_name" == *"$fragment"* ]]; then
                print -- "$identity_name"
                return 0
            fi
        done
    done

    return 0
}

function notarize_file() {
    local file_path="$1"

    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$file_path" --wait --keychain-profile "$NOTARY_PROFILE"
        return
    fi

    if [[ -n "$APPLE_ID" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAM_ID" ]]; then
        xcrun notarytool submit "$file_path" --wait \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID"
        return
    fi

    echo "Skipping notarization for $file_path because no notarytool credentials were provided."
}

require_command xcodebuild
require_command plutil
require_command /usr/libexec/PlistBuddy
require_command ditto
require_command hdiutil
require_command codesign
require_command xcrun
require_command shasum
require_command iconutil
require_command security

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(detect_signing_identity)"
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        AUTO_DETECTED_SIGNING_IDENTITY=1
    fi
fi

if [[ -z "$BASE_URL" ]]; then
    echo "REMOTEOS_CONTROL_PLANE_BASE_URL is required for hosted packaging." >&2
    exit 1
fi

if [[ "$HOST_MODE" != "hosted" ]]; then
    echo "package_hosted_app.sh only supports hosted mode." >&2
    exit 1
fi

if [[ "${REMOTEOS_ALLOW_INSECURE_BASE_URL:-0}" != "1" && "$BASE_URL" != https://* ]]; then
    echo "Hosted packaging requires an HTTPS REMOTEOS_CONTROL_PLANE_BASE_URL. Set REMOTEOS_ALLOW_INSECURE_BASE_URL=1 to override for testing." >&2
    exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

if [[ -z "$ICON_FILE" ]]; then
    ICON_FILE="$DIST_DIR/$APP_NAME.icns"
    "$APP_DIR/scripts/generate_hosted_icon.swift" "$ICON_FILE"
fi

typeset -a xcodebuild_args
xcodebuild_args=(
    -scheme RemoteOSHost
    -configuration Release
    -destination "platform=macOS"
    -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ -n "$ARCHS" ]]; then
    xcodebuild_args+=(
        ARCHS="$ARCHS"
        ONLY_ACTIVE_ARCH=NO
    )
fi

xcodebuild_args+=(build)

echo "Building Release bundle for hosted distribution..."
if command -v xcpretty >/dev/null 2>&1; then
    (
        cd "$APP_DIR"
        xcodebuild "${xcodebuild_args[@]}" | xcpretty
    )
else
    (
        cd "$APP_DIR"
        xcodebuild "${xcodebuild_args[@]}"
    )
fi

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Release"
EXECUTABLE_PATH="$PRODUCTS_DIR/RemoteOSHost"
RESOURCE_BUNDLE_PATH="$PRODUCTS_DIR/RemoteOSHost_RemoteOSHost.bundle"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "Expected executable was not found at $EXECUTABLE_PATH" >&2
    exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
    echo "Expected resource bundle was not found at $RESOURCE_BUNDLE_PATH" >&2
    exit 1
fi

mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_ROOT/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_ROOT/Contents/MacOS/$APP_NAME"
cp -R "$RESOURCE_BUNDLE_PATH" "$APP_ROOT/Contents/Resources/"

DEFAULTS_PATH="$APP_ROOT/Contents/Resources/$(basename "$RESOURCE_BUNDLE_PATH")/Contents/Resources/DefaultConfiguration.plist"
rm -f "$DEFAULTS_PATH"
plutil -create xml1 "$DEFAULTS_PATH"
/usr/libexec/PlistBuddy -c "Add :controlPlaneBaseURL string $BASE_URL" "$DEFAULTS_PATH"
/usr/libexec/PlistBuddy -c "Add :hostMode string $HOST_MODE" "$DEFAULTS_PATH"

INFO_PLIST_PATH="$APP_ROOT/Contents/Info.plist"
rm -f "$INFO_PLIST_PATH"
plutil -create xml1 "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_IDENTIFIER" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MINIMUM_MACOS_VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$INFO_PLIST_PATH"

if [[ -n "$ICON_FILE" ]]; then
    if [[ ! -f "$ICON_FILE" ]]; then
        echo "REMOTEOS_ICON_FILE points to a missing file: $ICON_FILE" >&2
        exit 1
    fi

    local_icon_name="$(basename "$ICON_FILE")"
    cp "$ICON_FILE" "$APP_ROOT/Contents/Resources/$local_icon_name"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ${local_icon_name%.*}" "$INFO_PLIST_PATH"
fi

ENTITLEMENTS_FILE="$APP_DIR/Resources/RemoteOS.entitlements"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
        echo "Signing app with Developer ID identity..."
        codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGNING_IDENTITY" "$APP_ROOT"
    else
        if [[ "$AUTO_DETECTED_SIGNING_IDENTITY" == "1" ]]; then
            echo "Signing app with auto-detected local identity: $SIGNING_IDENTITY"
        else
            echo "Signing app with identity: $SIGNING_IDENTITY"
        fi
        codesign --force --sign "$SIGNING_IDENTITY" "$APP_ROOT"
    fi
else
    echo "No signing identity provided. Applying ad-hoc signing for local verification only."
    echo "Warning: ad-hoc signing changes the app's code requirement on rebuilds, so macOS may invalidate Accessibility and Screen Recording grants after each packaged build."
    codesign --force --sign - "$APP_ROOT"
fi

codesign --verify --deep --strict --verbose=2 "$APP_ROOT"

echo "Creating ZIP artifact..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" || ( -n "$APPLE_ID" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAM_ID" ) ]]; then
    echo "Submitting ZIP for notarization..."
    notarize_file "$ZIP_PATH"
    xcrun stapler staple "$APP_ROOT"
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$ZIP_PATH"
fi

DMG_STAGING_DIR="$DIST_DIR/dmg-root"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_ROOT" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

echo "Creating DMG artifact..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

if [[ -n "$NOTARY_PROFILE" || ( -n "$APPLE_ID" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAM_ID" ) ]]; then
    echo "Submitting DMG for notarization..."
    notarize_file "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
fi

rm -rf "$DMG_STAGING_DIR"

{
    shasum -a 256 "$ZIP_PATH"
    shasum -a 256 "$DMG_PATH"
} >"$CHECKSUM_PATH"

echo
echo "Hosted build artifacts:"
echo "  App: $APP_ROOT"
echo "  ZIP: $ZIP_PATH"
echo "  DMG: $DMG_PATH"
echo "  Checksums: $CHECKSUM_PATH"
