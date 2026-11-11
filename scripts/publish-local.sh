#!/usr/bin/env bash
# Build, sign, notarize and package the version in Info.plist on this Mac,
# the way the release workflow would if it had the signing secrets.
#
#   scripts/publish-local.sh                 # build into dist/, nothing uploaded
#   scripts/publish-local.sh --upload        # also create the GitHub release for the tag
#   scripts/publish-local.sh --no-notarize   # sign only, for checking the package
#
# Environment:
#   SIGN_IDENTITY    "Developer ID Application: …" (default: the first one in the keychain)
#   NOTARY_PROFILE   notarytool Keychain profile (default: fnspeak), see scripts/notarize.sh
#   LLAMA_SERVER     llama-server to bundle (default: build/llama-server)
#   DIST_DIR         where the dmg and zip are written (default: dist/)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPLOAD=0
NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=1 ;;
        --no-notarize) NOTARIZE=0 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
if [[ "$UPLOAD" == 1 && "$NOTARIZE" == 0 ]]; then
    echo "refusing to upload a build that isn't notarized" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' apps/mac/Support/Info.plist)"
TAG="v$VERSION"
export SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-fnspeak}"
export LLAMA_SERVER="${LLAMA_SERVER:-$ROOT/build/llama-server}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "no Developer ID Application certificate in the keychain" >&2
    exit 1
fi
if [[ ! -x "$LLAMA_SERVER" ]]; then
    echo "no llama-server at $LLAMA_SERVER; run scripts/build-llama-server.sh" >&2
    exit 1
fi
if [[ "$UPLOAD" == 1 ]]; then
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "tag $TAG doesn't exist; cut it with scripts/release.sh" >&2; exit 1; }
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$TAG^{commit}")" ]]; then
        echo "HEAD isn't $TAG; check out the tag before uploading" >&2
        exit 1
    fi
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "working tree has changes" >&2; exit 1; }
fi

echo "==> FnSpeak $VERSION, signed as $SIGN_IDENTITY"
SIGN_ID="$SIGN_IDENTITY" scripts/build-mac.sh

DIST="${DIST_DIR:-$ROOT/dist}"
mkdir -p "$DIST"
DMG="$DIST/FnSpeak-$VERSION.dmg"
ZIP="$DIST/FnSpeak-$VERSION.zip"

if [[ "$NOTARIZE" == 1 ]]; then
    scripts/notarize.sh build/FnSpeak.app
else
    # Hardened runtime, as notarize.sh would sign it, so the package is realistic.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" build/FnSpeak.app/Contents/Frameworks/*.dylib \
        build/FnSpeak.app/Contents/Resources/llama-server build/FnSpeak.app/Contents/MacOS/fnspeak-mcp
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --entitlements apps/mac/Support/FnSpeak.entitlements build/FnSpeak.app
fi
codesign --verify --deep --strict build/FnSpeak.app

scripts/make-dmg.sh build/FnSpeak.app "$DMG"
rm -f "$ZIP"
ditto -c -k --keepParent build/FnSpeak.app "$ZIP"
if [[ "$NOTARIZE" == 1 ]]; then
    scripts/notarize.sh "$DMG"
fi
(cd "$DIST" && shasum -a 256 "FnSpeak-$VERSION.dmg" "FnSpeak-$VERSION.zip" | tee SHA256SUMS)

if [[ "$UPLOAD" == 1 ]]; then
    gh release create "$TAG" "$DMG" "$ZIP" "$DIST/SHA256SUMS" --title "FnSpeak $VERSION" --generate-notes --verify-tag
    echo "==> Published $TAG. Put the dmg's sha256 above into homebrew/fnspeak.rb."
else
    echo "==> Built $DMG"
    [[ "$NOTARIZE" == 1 ]] && echo "    Upload it with: scripts/publish-local.sh --upload"
fi
