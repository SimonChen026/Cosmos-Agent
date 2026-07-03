#!/bin/zsh
# Builds dist/Cosmos.dmg — a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_app.sh

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/Cosmos.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f dist/Cosmos.dmg
hdiutil create -volname "Cosmos" -srcfolder "$STAGE" -ov -format UDZO dist/Cosmos.dmg
echo "wrote dist/Cosmos.dmg"
