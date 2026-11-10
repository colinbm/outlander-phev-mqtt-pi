#!/bin/bash
# Pack this folder into phev-bridge.tgz for copying to a Pi (see "Installing on a new Pi").
set -euo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
cd "$(dirname "$REPO")"
NAME=$(basename "$REPO")
COPYFILE_DISABLE=1 tar czf "$NAME/phev-bridge.tgz" --no-xattrs --no-mac-metadata \
    --exclude .DS_Store --exclude exclude/ --exclude phev-bridge.tgz --exclude __pycache__ \
    -s ",^$NAME,phev-bridge," "$NAME"
ls -l "$NAME/phev-bridge.tgz"
