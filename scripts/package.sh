#!/bin/bash
# Builds the archive that site/install.sh downloads: dist/PartyPortal-<arch>.zip and its checksum.
# Attach both files to a GitHub release; the installer takes them from the latest one.
# cloudflared is not inside: the installer downloads the one for the Mac it runs on.
#
# Signed ad hoc on purpose. A personal certificate would put its owner's name in every copy, and an
# Apple Development one does not make the app open on other Macs anyway. Until there is a Developer ID,
# the price is that macOS asks for the two permissions again after every update.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PP_SIGN_IDENTITY=- PP_CLOUDFLARED= PP_INSTALL_DIR="$STAGE" ./scripts/build-app.sh

APP="$STAGE/PartyPortal.app"
codesign --verify --deep --strict "$APP"

NAME="PartyPortal-$(uname -m).zip"
mkdir -p dist
rm -f "dist/$NAME" "dist/$NAME.sha256"
ditto -c -k --keepParent "$APP" "dist/$NAME"
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")

echo "Done: dist/$NAME ($(du -h "dist/$NAME" | cut -f1 | tr -d ' ')), dist/$NAME.sha256"
