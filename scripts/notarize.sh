#!/usr/bin/env bash
# Sign with a Developer ID and notarize a Flowstate.app or a .dmg.
#
#   scripts/notarize.sh build/Flowstate.app    # re-sign (hardened runtime), notarize, staple
#   scripts/notarize.sh build/Flowstate-0.1.0.dmg   # sign the disk image, notarize, staple
#
# Environment (the same names the release workflow takes from repo secrets):
#   APPLE_ID                      Apple ID used for notarytool
#   APPLE_TEAM_ID                 10-character team ID
#   APPLE_APP_PASSWORD            app-specific password for that Apple ID
#   DEVELOPER_ID_CERT_P12_BASE64  base64 of the "Developer ID Application" .p12
#   DEVELOPER_ID_CERT_PASSWORD    password for the .p12
#
# Locally, if the certificate is already in your keychain you can skip the two
# DEVELOPER_ID_CERT_* variables and set SIGN_IDENTITY instead, e.g.
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/apps/mac/Support/Flowstate.entitlements"
TARGET="${1:-}"

if [[ -z "$TARGET" || ! -e "$TARGET" ]]; then
    echo "usage: $0 <Flowstate.app | file.dmg>" >&2
    exit 2
fi

missing=()
for var in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
done
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    for var in DEVELOPER_ID_CERT_P12_BASE64 DEVELOPER_ID_CERT_PASSWORD; do
        [[ -n "${!var:-}" ]] || missing+=("$var")
    done
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "missing environment: ${missing[*]}" >&2
    exit 1
fi

WORK="$(mktemp -d)"
KEYCHAIN=""
cleanup() {
    if [[ -n "$KEYCHAIN" ]]; then
        security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

import_certificate() {
    KEYCHAIN="$WORK/signing.keychain-db"
    local pass p12
    pass="$(uuidgen)"
    p12="$WORK/cert.p12"
    printf '%s' "$DEVELOPER_ID_CERT_P12_BASE64" | base64 --decode > "$p12"
    security create-keychain -p "$pass" "$KEYCHAIN"
    security set-keychain-settings -lut 3600 "$KEYCHAIN"
    security unlock-keychain -p "$pass" "$KEYCHAIN"
    security import "$p12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$KEYCHAIN" >/dev/null
    # Put it first in the search list so codesign finds it.
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
    rm -f "$p12"
}

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    import_certificate
    SIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "no 'Developer ID Application' identity found in the supplied certificate" >&2
        exit 1
    fi
fi
echo "==> Signing as: $SIGN_IDENTITY"

sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }

submit_and_staple() {
    local file="$1"
    echo "==> Submitting $(basename "$file") to Apple notary service"
    xcrun notarytool submit "$file" \
        --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
        --wait --timeout 30m
    echo "==> Stapling"
    xcrun stapler staple "${2:-$file}"
}

case "$TARGET" in
    *.app)
        APP="${TARGET%/}"
        # Sign inside-out: nested code first, the bundle last.
        for lib in "$APP"/Contents/Frameworks/*.dylib; do
            [[ -e "$lib" ]] && sign "$lib"
        done
        if [[ -f "$APP/Contents/Resources/llama-server" ]]; then
            sign "$APP/Contents/Resources/llama-server"
        fi
        sign "$APP/Contents/MacOS/flowstate-mcp"
        sign --entitlements "$ENTITLEMENTS" "$APP"
        codesign --verify --deep --strict --verbose=2 "$APP"

        ZIP="$WORK/notarize.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        submit_and_staple "$ZIP" "$APP"
        xcrun stapler validate "$APP"
        ;;
    *.dmg)
        sign "$TARGET"
        submit_and_staple "$TARGET"
        xcrun stapler validate "$TARGET"
        ;;
    *)
        echo "expected a .app or .dmg, got: $TARGET" >&2
        exit 2
        ;;
esac

echo "==> Notarized: $TARGET"
