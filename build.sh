#!/bin/bash
# Build the patched phev2mqtt binaries that install.sh puts on the Pi.
#
#   ./build.sh            uses `go` from PATH (or GO=/path/to/go ./build.sh)
#
# Produces dist/phev2mqtt-linux-armv6 (32-bit Pi OS, every Pi) and
# dist/phev2mqtt-linux-arm64 (64-bit Pi OS), plus dist/SHA256SUMS.
set -euo pipefail
cd "$(dirname "$0")"
GO=${GO:-go}
COMMIT=8f42340
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone -q https://github.com/buxtronix/phev2mqtt.git "$WORK/src"
cd "$WORK/src"
git checkout -q "$COMMIT"
git apply "$ROOT"/patches/*.patch

export CGO_ENABLED=0 GOOS=linux GOTOOLCHAIN=local GOFLAGS=-mod=mod
export GOPATH="$WORK/gopath" GOCACHE="$WORK/gocache"
mkdir -p "$ROOT/dist"
GOARCH=arm GOARM=6 "$GO" build -trimpath -ldflags="-s -w" -o "$ROOT/dist/phev2mqtt-linux-armv6" .
GOARCH=arm64 "$GO" build -trimpath -ldflags="-s -w" -o "$ROOT/dist/phev2mqtt-linux-arm64" .
chmod -R u+w "$WORK"   # the Go module cache is read-only, which trips up the cleanup

cd "$ROOT/dist"
shasum -a 256 phev2mqtt-linux-* > SHA256SUMS
cat SHA256SUMS
