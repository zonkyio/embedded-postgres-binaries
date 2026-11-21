#!/bin/sh
set -eu

if [ -z "${BUNDLE_FILE:-}" ]; then
    echo "BUNDLE_FILE environment variable is required!" >&2
    exit 1
fi
if [ -z "${REPO_DIR:-}" ]; then
    echo "REPO_DIR environment variable is required!" >&2
    exit 1
fi

env ASSUME_ALWAYS_YES=yes pkg bootstrap
env ASSUME_ALWAYS_YES=yes pkg update
env ASSUME_ALWAYS_YES=yes pkg install \
    ca_root_nss \
    go \
    git

BINARIES_PATH=/var/tmp/embedded-postgres-binaries
RUNTIME_PATH=/var/tmp/embedded-postgres-runtime
DATA_PATH=/var/tmp/embedded-postgres-data

rm -rf "$BINARIES_PATH" "$RUNTIME_PATH" "$DATA_PATH"
mkdir -p "$BINARIES_PATH" /usr/local/share
tar -xJf "$BUNDLE_FILE" -C "$BINARIES_PATH"

if [ -d "$BINARIES_PATH/share/icu" ]; then
    rm -rf /usr/local/share/icu
    cp -Rp "$BINARIES_PATH/share/icu" /usr/local/share/
fi

cd "$REPO_DIR/examples"
env \
    EMBEDDED_POSTGRES_BINARIES_PATH="$BINARIES_PATH" \
    EMBEDDED_POSTGRES_RUNTIME_PATH="$RUNTIME_PATH" \
    EMBEDDED_POSTGRES_DATA_PATH="$DATA_PATH" \
    EMBEDDED_POSTGRES_PORT=65432 \
    go test ./... \
    -count=1 \
    -v
