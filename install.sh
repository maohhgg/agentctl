#!/bin/sh
# agentctl installer — downloads the single-file CLI into a bin directory.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/maohhgg/agentctl/main/install.sh | sh
#
# Overrides:
#   DEST=/usr/local/bin curl -fsSL ... | sh     # install location
#   REF=v1.1.0 curl -fsSL ... | sh              # pin a tag instead of main
set -eu

REPO="${AGENTCTL_REPO:-maohhgg/agentctl}"
REF="${REF:-main}"
DEST="${DEST:-$HOME/.local/bin}"

BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        echo "error: need curl or wget to download" >&2
        exit 1
    fi
}

fetch "${BASE}/agentctl" "$TMP"
command -v node >/dev/null 2>&1 || {
    echo "error: node >= 20 is required on PATH (https://nodejs.org)" >&2
    exit 1
}

mkdir -p "$DEST"
chmod +x "$TMP"
mv "$TMP" "${DEST}/agentctl"

echo "installed: ${DEST}/agentctl ($(${DEST}/agentctl --version))"
case ":${PATH}:" in
    *":${DEST}:"*) ;;
    *) echo "note: ${DEST} is not on PATH — add it to your shell profile:" ;;
esac
