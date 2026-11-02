#!/usr/bin/env bash
# Package Flowstate.app into a drag-to-Applications disk image with hdiutil.
#
#   scripts/make-dmg.sh build/Flowstate.app build/Flowstate-0.1.0.dmg
set -euo pipefail

APP="${1:-}"
OUT="${2:-}"
if [[ -z "$APP" || -z "$OUT" || ! -d "$APP" ]]; then
    echo "usage: $0 <Flowstate.app> <output.dmg>" >&2
    exit 2
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Flowstate.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "Flowstate" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "built $OUT"
