#!/bin/zsh
#
# Local Sparkle update smoke test.
#
# Builds two hosted app versions (old + new), generates a local appcast,
# and starts a local HTTP server so you can verify the full update flow:
#
#   1.  Install the OLD build (drag to /Applications or run from dist).
#   2.  Launch it — the Updates section should appear in Settings.
#   3.  Click "Check for Updates…" — Sparkle should find the NEW version.
#   4.  Accept the update — Sparkle downloads the DMG, installs, relaunches.
#   5.  Verify the version number in Settings changed to the NEW version.
#
# Requirements:
#   - REMOTEOS_CONTROL_PLANE_BASE_URL must be set (or use --allow-insecure)
#   - No signing identity needed — ad-hoc signing is fine for local testing
#
# Usage:
#   REMOTEOS_CONTROL_PLANE_BASE_URL=https://your-cp.example.com \
#     apps/macos/scripts/test_sparkle_update.sh
#
#   # Or for a fully offline test (no real control plane):
#   REMOTEOS_CONTROL_PLANE_BASE_URL=http://localhost:9999 \
#   REMOTEOS_ALLOW_INSECURE_BASE_URL=1 \
#     apps/macos/scripts/test_sparkle_update.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$ROOT_DIR/apps/macos"
TEST_DIR="$ROOT_DIR/dist/sparkle-test"
SPARKLE_TOOLS_DIR="$TEST_DIR/sparkle-tools"
SERVE_DIR="$TEST_DIR/serve"
OLD_DIR="$TEST_DIR/old"
NEW_DIR="$TEST_DIR/new"
SERVE_PORT="${SPARKLE_TEST_PORT:-8089}"

OLD_VERSION="0.1.0"
OLD_BUILD="100"
NEW_VERSION="0.2.0"
NEW_BUILD="200"

APP_NAME="${REMOTEOS_APP_NAME:-RemoteOS}"

# ── Download Sparkle CLI tools ────────────────────────────────────────

function fetch_sparkle_tools() {
    if [[ -x "$SPARKLE_TOOLS_DIR/bin/generate_appcast" ]]; then
        echo "Sparkle tools already present."
        return 0
    fi

    echo "Downloading Sparkle 2.9.0 distribution..."
    local archive_path="$TEST_DIR/Sparkle-2.9.0.tar.xz"
    mkdir -p "$SPARKLE_TOOLS_DIR"
    curl -fsSL \
        -o "$archive_path" \
        "https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz"
    tar -xJf "$archive_path" -C "$SPARKLE_TOOLS_DIR"
    rm -f "$archive_path"
    echo "Sparkle tools extracted to $SPARKLE_TOOLS_DIR"
}

# ── Generate or reuse Ed25519 keypair ────────────────────────────────

function ensure_keypair() {
    local key_file="$TEST_DIR/sparkle_test_private_key"
    local pub_file="$TEST_DIR/sparkle_test_public_key"

    if [[ -f "$key_file" && -f "$pub_file" ]]; then
        echo "Reusing existing test keypair."
        SPARKLE_PUBLIC_KEY="$(cat "$pub_file")"
        SPARKLE_PRIVATE_KEY_FILE="$key_file"
        return 0
    fi

    echo "Generating Sparkle Ed25519 test keypair..."
    # generate_keys writes to Keychain by default; use -x to export
    "$SPARKLE_TOOLS_DIR/bin/generate_keys" -p 2>/dev/null && true

    # Export private key from Keychain to a file
    "$SPARKLE_TOOLS_DIR/bin/generate_keys" -x "$key_file"
    SPARKLE_PUBLIC_KEY="$("$SPARKLE_TOOLS_DIR/bin/generate_keys" -p 2>/dev/null)"
    echo "$SPARKLE_PUBLIC_KEY" > "$pub_file"

    SPARKLE_PRIVATE_KEY_FILE="$key_file"
    echo "Public key: $SPARKLE_PUBLIC_KEY"
}

# ── Build a hosted app version ────────────────────────────────────────

function build_version() {
    local version="$1"
    local build_number="$2"
    local output_dir="$3"

    echo ""
    echo "━━━ Building version $version (build $build_number) ━━━"

    REMOTEOS_VERSION="$version" \
    REMOTEOS_BUILD_NUMBER="$build_number" \
    REMOTEOS_DIST_DIR="$output_dir" \
    REMOTEOS_SPARKLE_FEED_URL="http://localhost:$SERVE_PORT/appcast.xml" \
    REMOTEOS_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_KEY" \
    REMOTEOS_ALLOW_INSECURE_BASE_URL="${REMOTEOS_ALLOW_INSECURE_BASE_URL:-0}" \
    REMOTEOS_CONTROL_PLANE_BASE_URL="${REMOTEOS_CONTROL_PLANE_BASE_URL:?Set REMOTEOS_CONTROL_PLANE_BASE_URL}" \
        "$APP_DIR/scripts/package_hosted_app.sh"

    # Patch Info.plist to allow local HTTP networking (ATS exception for localhost)
    local info_plist="$output_dir/$APP_NAME.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$info_plist"

    # Re-sign after patching Info.plist (ad-hoc)
    codesign --force --sign - --deep "$output_dir/$APP_NAME.app"

    echo "Built: $output_dir/$APP_NAME.app"
    echo "  Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
    echo "  Build:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
    echo "  Feed:    $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")"
}

# ── Generate appcast ──────────────────────────────────────────────────

function generate_appcast() {
    echo ""
    echo "━━━ Generating local appcast ━━━"

    local appcast_input="$TEST_DIR/appcast-input"
    rm -rf "$appcast_input"
    mkdir -p "$appcast_input" "$SERVE_DIR"

    # Only the NEW version's DMG goes into the appcast
    cp "$NEW_DIR/$APP_NAME.dmg" "$appcast_input/"

    "$SPARKLE_TOOLS_DIR/bin/generate_appcast" \
        --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
        --download-url-prefix "http://localhost:$SERVE_PORT/" \
        --maximum-versions 1 \
        --maximum-deltas 0 \
        -o "$SERVE_DIR/appcast.xml" \
        "$appcast_input"

    # Copy the NEW DMG to the serve directory so it can be downloaded
    cp "$NEW_DIR/$APP_NAME.dmg" "$SERVE_DIR/"

    echo "Appcast: $SERVE_DIR/appcast.xml"
    echo ""
    echo "Appcast contents:"
    cat "$SERVE_DIR/appcast.xml"
}

# ── Main ──────────────────────────────────────────────────────────────

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

fetch_sparkle_tools
ensure_keypair

build_version "$OLD_VERSION" "$OLD_BUILD" "$OLD_DIR"
build_version "$NEW_VERSION" "$NEW_BUILD" "$NEW_DIR"
generate_appcast

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Local Sparkle update test is ready."
echo ""
echo "  OLD app ($OLD_VERSION): $OLD_DIR/$APP_NAME.app"
echo "  NEW app ($NEW_VERSION): $NEW_DIR/$APP_NAME.app"
echo "  Serve directory:        $SERVE_DIR"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Start the local server (leave it running):"
echo ""
echo "       cd $SERVE_DIR && python3 -m http.server $SERVE_PORT"
echo ""
echo "  2. In a new terminal, launch the OLD app:"
echo ""
echo "       open $OLD_DIR/$APP_NAME.app"
echo ""
echo "  3. In the app, open Settings and look for the 'Updates' section."
echo "     Click 'Check for Updates…'."
echo ""
echo "  4. Sparkle should find version $NEW_VERSION and offer to install it."
echo "     Accept the update and verify the app relaunches with the new version."
echo ""
echo "  5. After testing, stop the server with Ctrl-C."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
