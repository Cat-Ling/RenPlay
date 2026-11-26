#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build a single dynamic iOS .framework + Python runtime pack from an official
# renpy/renpy release (renios.zip + sdk.zip). Designed to run on a macOS runner.

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <release_tag> <short_version> <framework_name> [output_dir]" >&2
    exit 2
fi

TAG="$1"
VER="$2"
FW_NAME="$3"
OUT_DIR="${4:-$PWD/out}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/renplay-build-${VER}.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR/frameworks" "$OUT_DIR/engines" "$OUT_DIR/metadata"

RENIOS_ZIP="$WORK_DIR/renpy-${VER}-renios.zip"
SDK_ZIP="$WORK_DIR/renpy-${VER}-sdk.zip"
RENIOS_DIR="$WORK_DIR/renios"
SDK_DIR="$WORK_DIR/sdk"

BASE_URL="https://github.com/renpy/renpy/releases/download/${TAG}"
echo "Downloading renpy-${VER}-renios.zip and renpy-${VER}-sdk.zip from ${TAG}..."
curl -fsSL --retry 3 "${BASE_URL}/renpy-${VER}-renios.zip" -o "$RENIOS_ZIP"
curl -fsSL --retry 3 "${BASE_URL}/renpy-${VER}-sdk.zip" -o "$SDK_ZIP"

mkdir -p "$RENIOS_DIR" "$SDK_DIR"
unzip -q "$RENIOS_ZIP" -d "$RENIOS_DIR"
unzip -q "$SDK_ZIP" -d "$SDK_DIR"

# Locate prototype/ inside extracted renios.zip
PROTO_DIR="$(find "$RENIOS_DIR" -maxdepth 4 -type d -name prototype | head -n 1)"
if [ -z "$PROTO_DIR" ] || [ ! -d "$PROTO_DIR/prebuilt/release" ]; then
    echo "Error: Could not find prototype/prebuilt/release inside $RENIOS_ZIP" >&2
    find "$RENIOS_DIR" -maxdepth 4 >&2
    exit 1
fi
PREBUILT_DIR="$PROTO_DIR/prebuilt/release"
PBXPROJ="$PROTO_DIR/prototype.xcodeproj/project.pbxproj"

# Locate extracted SDK root (contains renpy/)
SDK_ROOT="$(dirname "$(find "$SDK_DIR" -maxdepth 3 -type d -name renpy | head -n 1)")"
if [ -z "$SDK_ROOT" ] || [ ! -d "$SDK_ROOT/renpy" ]; then
    echo "Error: Could not find renpy/ directory inside $SDK_ZIP" >&2
    exit 1
fi

# Locate MetalANGLE.framework (device slice only, never *-simulator)
METALANGLE_SRC="$(find "$PROTO_DIR" -path "*/ios-arm64/MetalANGLE.framework" -type d | head -n 1)"
if [ -z "$METALANGLE_SRC" ]; then
    METALANGLE_SRC="$(find "$PROTO_DIR" -name "MetalANGLE.framework" -type d -not -path "*-simulator*" | head -n 1)"
fi
if [ -z "$METALANGLE_SRC" ]; then
    echo "Error: MetalANGLE.framework not found in $PROTO_DIR" >&2
    exit 1
fi

echo "Found prototype: $PROTO_DIR"
echo "Found SDK root:  $SDK_ROOT"
echo "Found MetalANGLE: $METALANGLE_SRC"

# Inspect MetalANGLE.framework: verify whether it is a dynamic framework or static archive
METALANGLE_BIN="$METALANGLE_SRC/MetalANGLE"
echo "MetalANGLE file type: $(file "$METALANGLE_BIN")"

# Detect Python version and SDL version from prebuilt libraries
PY_LIB="$(find "$PREBUILT_DIR" -maxdepth 1 -name 'libpython*.a' | sort -V | tail -n 1)"
PY_VER="$(basename "$PY_LIB" | sed -E 's/^libpython([0-9]+\.[0-9]+)\.a$/\1/')"
if ls "$PREBUILT_DIR"/libSDL3*.a >/dev/null 2>&1; then
    SDL_VER="SDL3"
else
    SDL_VER="SDL2"
fi
echo "Detected Python: $PY_VER | SDL: $SDL_VER"

# Compile C entry shim that initializes SDL main readiness and calls launcher_main
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"

cat > "$WORK_DIR/renplay_entry.c" << 'EOF'
#include <stddef.h>

extern int launcher_main(int argc, char **argv);
extern void SDL_SetMainReady(void) __attribute__((weak));

__attribute__((visibility("default")))
int renplay_launch(int argc, char **argv) {
    if (SDL_SetMainReady != NULL) {
        SDL_SetMainReady();
    }
    return launcher_main(argc, argv);
}
EOF

"$CLANG" -c "$WORK_DIR/renplay_entry.c" \
    -arch arm64 \
    -isysroot "$IOS_SDK" \
    -miphoneos-version-min=15.0 \
    -fvisibility=default \
    -o "$WORK_DIR/renplay_entry.o"

# Build link flags from project.pbxproj OTHER_LDFLAGS, keeping only libs that exist in PREBUILT_DIR or system
LINKER_LIBS=()
if [ -f "$PBXPROJ" ]; then
    # Extract "-l..." tokens from OTHER_LDFLAGS, filtering python version for dual-py releases
    while IFS= read -r flag; do
        [ -z "$flag" ] && continue
        if [[ "$flag" == -lpython* ]] || [ "$flag" = "-lrenpython" ] || [ "$flag" = "-lrenpy" ]; then
            continue
        fi
        LIB_NAME="${flag#-l}"
        if [ -f "$PREBUILT_DIR/lib${LIB_NAME}.a" ] || [[ "$flag" =~ ^-l(stdc\+\+|c\+\+|z|bz2|lzma|iconv)$ ]]; then
            LINKER_LIBS+=("$flag")
        fi
    done < <(python3 - "$PBXPROJ" << 'PYEOF'
import re, sys
text = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
m = re.search(r"OTHER_LDFLAGS\s*=\s*\((.*?)\);", text, re.S)
seen = set()
if m:
    for item in re.findall(r'"(-l[^"]+)"', m.group(1)):
        if item not in seen:
            seen.add(item)
            print(item)
PYEOF
)
fi

# Fallback/supplement: ensure any extra lib*.a in PREBUILT_DIR not yet included is added
for libfile in "$PREBUILT_DIR"/lib*.a; do
    base="$(basename "$libfile" .a)"
    name="${base#lib}"
    if [ "$name" = "renpython" ] || [ "$name" = "renpy" ] || [[ "$name" == python* ]] || [[ "$name" == *_test ]] || [ "$name" = "mockrt" ]; then
        continue
    fi
    flag="-l${name}"
    found=0
    for existing in "${LINKER_LIBS[@]:-}"; do
        if [ "$existing" = "$flag" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        LINKER_LIBS+=("$flag")
    fi
done

echo "Link libraries: ${LINKER_LIBS[*]}"

FW_DIR="$OUT_DIR/frameworks/${FW_NAME}.framework"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR"

# Ensure MetalANGLE binary contains arm64 and thin universal device slices if lipo is available
METALANGLE_OUT="$OUT_DIR/frameworks/MetalANGLE.framework"
rm -rf "$METALANGLE_OUT"
cp -R "$METALANGLE_SRC" "$METALANGLE_OUT"
if lipo -info "$METALANGLE_OUT/MetalANGLE" 2>/dev/null | grep -q "Architectures in the fat file"; then
    lipo "$METALANGLE_OUT/MetalANGLE" -thin arm64 -output "$METALANGLE_OUT/MetalANGLE.arm64"
    mv "$METALANGLE_OUT/MetalANGLE.arm64" "$METALANGLE_OUT/MetalANGLE"
fi

# Collect undefined-symbol hints so SDL input helpers are exported when present in libSDL
SDL_EXPORT_FLAGS=("-Wl,-u,_launcher_main")
SDL_NM="$(nm -g "$PREBUILT_DIR"/libSDL*.a 2>/dev/null || true)"
for sym in _SDL_PushEvent _SDL_StartTextInput _SDL_StopTextInput _SDL_GetKeyboardFocus; do
    if grep -Fq " T ${sym}" <<< "$SDL_NM"; then
        SDL_EXPORT_FLAGS+=("-Wl,-u,${sym}")
    fi
done

EXTRA_SYS_FRAMEWORKS=()
if [ -d "$IOS_SDK/System/Library/Frameworks/DeclaredAgeRange.framework" ]; then
    EXTRA_SYS_FRAMEWORKS+=("-weak_framework" "DeclaredAgeRange")
fi

# Link the dynamic framework without -force_load (avoids duplicate archive members in upstream librenpy.a).
# Place -lpython${PY_VER} before LINKER_LIBS (-lffi) so Python's symbols resolve in upstream order.
"$CLANG" -dynamiclib \
    -arch arm64 \
    -isysroot "$IOS_SDK" \
    -miphoneos-version-min=15.0 \
    -install_name "@rpath/${FW_NAME}.framework/${FW_NAME}" \
    -Wl,-rpath,@loader_path/.. \
    -Wl,-rpath,@executable_path/Frameworks \
    -F "$(dirname "$METALANGLE_OUT")" \
    -L "$PREBUILT_DIR" \
    "$WORK_DIR/renplay_entry.o" \
    "${SDL_EXPORT_FLAGS[@]}" \
    -lrenpython \
    -lrenpy \
    "-lpython${PY_VER}" \
    "${LINKER_LIBS[@]}" \
    -framework MetalANGLE \
    -framework Metal \
    -framework CoreVideo \
    -framework UIKit \
    -framework Foundation \
    -framework CoreGraphics \
    -framework AudioToolbox \
    -framework QuartzCore \
    -framework ImageIO \
    -framework CoreMotion \
    -framework CoreBluetooth \
    -framework CoreHaptics \
    -framework GameController \
    -framework CoreServices \
    -framework AVFoundation \
    -framework OpenGLES \
    -framework Security \
    -framework StoreKit \
    -framework MobileCoreServices \
    "${EXTRA_SYS_FRAMEWORKS[@]}" \
    -lc++ -lbz2 -lz -liconv \
    -o "$FW_DIR/$FW_NAME"

strip -x "$FW_DIR/$FW_NAME"

BUNDLE_ID_SUFFIX="${FW_NAME//_/-}"
cat > "$FW_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FW_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.catling.RenPlay.${BUNDLE_ID_SUFFIX}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FW_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${VER}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>15.0</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
</dict>
</plist>
EOF

plutil -lint "$FW_DIR/Info.plist"

echo "=== Verification: otool -L ${FW_NAME} ==="
otool -L "$FW_DIR/$FW_NAME"
echo "=== Verification: exported entry symbols ==="
NM_EXPORTS="$(nm -gU "$FW_DIR/$FW_NAME")"
printf '%s\n' "$NM_EXPORTS" | grep -E '(_launcher_main|_renplay_launch|_SDL_PushEvent|_SDL_StartTextInput|_SDL_StopTextInput)' || true
if ! grep -Fq '_launcher_main' <<< "$NM_EXPORTS"; then
    echo "Error: _launcher_main not exported in $FW_DIR/$FW_NAME" >&2
    exit 1
fi
if ! grep -Fq '_renplay_launch' <<< "$NM_EXPORTS"; then
    echo "Error: _renplay_launch not exported in $FW_DIR/$FW_NAME" >&2
    exit 1
fi

# Package framework zip and already-thinned MetalANGLE.framework
(cd "$OUT_DIR/frameworks" && zip -q -r -y "renpy-${VER}-framework.zip" "${FW_NAME}.framework")
(cd "$OUT_DIR/frameworks" && zip -q -r -y "MetalANGLE.framework.zip" "MetalANGLE.framework")

# Assemble Python runtime pack: base/main.py, base/renpy/, base/lib/
STAGE="$WORK_DIR/engine_stage"
mkdir -p "$STAGE/base"

cp "$SCRIPT_DIR/engine_main.py" "$STAGE/base/main.py"
cp -R "$SDK_ROOT/renpy" "$STAGE/base/renpy"

# Copy iOS-specific base/lib (contains site.pyc/pyo, iossupport.py, pyobjus, python stdlib)
if [ -d "$PROTO_DIR/base/lib" ]; then
    cp -R "$PROTO_DIR/base/lib" "$STAGE/base/lib"
elif [ -d "$SDK_ROOT/lib/python${PY_VER}" ]; then
    mkdir -p "$STAGE/base/lib"
    cp -R "$SDK_ROOT/lib/python${PY_VER}" "$STAGE/base/lib/"
else
    echo "Error: No Python stdlib found in $PROTO_DIR/base/lib or $SDK_ROOT/lib" >&2
    exit 1
fi

# Ensure pyobjus / iossupport / site exist inside base/lib/python*
echo "Engine base/lib contents:"
ls -la "$STAGE/base/lib"

find "$STAGE/base" -name ".DS_Store" -delete

printf '%s\n' "$VER" > "$STAGE/base/script_version.txt"

(cd "$STAGE" && zip -q -r -y "$OUT_DIR/engines/renpy-${VER}-engine.zip" base)

# Write per-version metadata JSON
cat > "$OUT_DIR/metadata/${VER}.json" << EOF
{
  "id": "${VER}",
  "version": "${VER}",
  "releaseTag": "${TAG}",
  "frameworkName": "${FW_NAME}",
  "pythonVersion": "${PY_VER}",
  "sdlVersion": "${SDL_VER}",
  "engineArchive": "${VER}.zip"
}
EOF

echo "Built ${FW_NAME}.framework and renpy-${VER}-engine.zip successfully."
