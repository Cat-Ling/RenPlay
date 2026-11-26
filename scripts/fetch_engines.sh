#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Download built Ren'Py engine frameworks and Python script archives from
# GitHub Releases into BundleResources/ for xtool packaging.

set -euo pipefail

REPO="${RENPLAY_REPO:-Cat-Ling/RenPlay}"
RELEASE_TAG="${1:-engines-v1}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="$ROOT_DIR/BundleResources/Frameworks"
ENG_DIR="$ROOT_DIR/BundleResources/Engines"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/renplay-fetch.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$FW_DIR" "$ENG_DIR"

echo "Downloading release '${RELEASE_TAG}' assets from ${REPO}..."
gh release download "$RELEASE_TAG" --repo "$REPO" --dir "$TMP_DIR" --clobber

rm -rf "$FW_DIR"/*.framework
rm -f "$ENG_DIR"/*.zip "$ENG_DIR"/engines-manifest.json

if [ -f "$TMP_DIR/MetalANGLE.framework.zip" ]; then
    unzip -q -o "$TMP_DIR/MetalANGLE.framework.zip" -d "$FW_DIR"
fi

for f in "$TMP_DIR"/renpy-*-framework.zip; do
    [ -e "$f" ] || continue
    unzip -q -o "$f" -d "$FW_DIR"
done

for f in "$TMP_DIR"/renpy-*-engine.zip; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    ver="${base#renpy-}"
    ver="${ver%-engine.zip}"
    cp "$f" "$ENG_DIR/${ver}.zip"
done

cp "$TMP_DIR/engines-manifest.json" "$ENG_DIR/engines-manifest.json"

echo "Installed frameworks:"
ls -1 "$FW_DIR"
echo "Installed engine archives:"
ls -1 "$ENG_DIR"
