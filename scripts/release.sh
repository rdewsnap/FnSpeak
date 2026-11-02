#!/usr/bin/env bash
# Bump the version everywhere, commit "Release vX.Y.Z" and tag it. Nothing is pushed.
#
#   scripts/release.sh 0.2.0
#
# Touches: [workspace.package] version in Cargo.toml (and Cargo.lock),
# CFBundleShortVersionString and CFBundleVersion in apps/mac/Support/Info.plist.
# Run it on a clean `main`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.cargo/bin:$PATH"

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "usage: $0 <version>   e.g. $0 0.2.0 or $0 0.2.0-beta.1" >&2
    exit 2
fi
TAG="v$VERSION"
PLIST="apps/mac/Support/Info.plist"

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
    echo "refusing to release from '$branch'; switch to main first" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "refusing to release with a dirty working tree" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG already exists" >&2
    exit 1
fi

# Cargo.toml: only the version line inside [workspace.package].
sed -i.bak '/^\[workspace.package\]/,/^\[/ s/^version = ".*"/version = "'"$VERSION"'"/' Cargo.toml
rm -f Cargo.toml.bak

# Info.plist: marketing version is the release; the build number counts releases.
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if [[ "$build" =~ ^[0-9]+$ ]]; then
    build=$((build + 1))
else
    build=1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$PLIST"

# Refresh the workspace members' versions in Cargo.lock without touching dependencies.
cargo update --workspace --offline >/dev/null 2>&1 || cargo update --workspace >/dev/null

git add Cargo.toml Cargo.lock "$PLIST"
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Flowstate $VERSION"

echo "Tagged $TAG on $(git rev-parse --short HEAD)."
echo "Publish it with:"
echo "  git push origin main && git push origin $TAG"
