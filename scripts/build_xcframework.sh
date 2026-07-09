#!/usr/bin/env bash
# Build SimpleNESCore.xcframework from scratch — device (arm64-ios) + simulator (arm64-iphonesimulator).
# Run from the repo root:
#   scripts/build_xcframework.sh
# Output: dist/SimpleNESCore.xcframework
#
# Requires: cmake >= 3.13, Xcode with iOS SDK.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DEVICE=build-ios
BUILD_SIM=build-ios-sim
DIST_DIR=dist
TOOLCHAIN=cmake/Modules/ios.toolchain.cmake
DEPLOYMENT_TARGET=14.0

echo "==> Cleaning previous build directories"
rm -rf "$BUILD_DEVICE" "$BUILD_SIM" "$DIST_DIR/SimpleNESCore.xcframework"
mkdir -p "$DIST_DIR"

build_one() {
    local dir="$1"
    local platform="$2"
    local label="$3"

    echo "==> Configuring $label ($platform)"
    mkdir -p "$dir"
    (cd "$dir" && cmake -G Xcode \
        -DCMAKE_TOOLCHAIN_FILE="../$TOOLCHAIN" \
        -DPLATFORM="$platform" \
        -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        .. > /dev/null)

    echo "==> Building $label"
    (cd "$dir" && cmake --build . --config Release --target SimpleNESCore > /dev/null)
}

build_one "$BUILD_DEVICE" OS64            "iOS device (arm64)"
build_one "$BUILD_SIM"    SIMULATORARM64  "iOS simulator (arm64)"

DEVICE_LIB="$BUILD_DEVICE/Release-iphoneos/libSimpleNESCore.a"
SIM_LIB="$BUILD_SIM/Release-iphonesimulator/libSimpleNESCore.a"

if [[ ! -f "$DEVICE_LIB" || ! -f "$SIM_LIB" ]]; then
    echo "ERROR: expected static libraries not produced" >&2
    exit 1
fi

# xcodebuild -create-xcframework wants a headers directory per library. Both slices share the same
# public headers (include/) so we just point at the repo's include/ directory for each slice.
echo "==> Creating SimpleNESCore.xcframework"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers include \
    -library "$SIM_LIB"    -headers include \
    -output "$DIST_DIR/SimpleNESCore.xcframework"

echo "==> Done: $DIST_DIR/SimpleNESCore.xcframework"
ls "$DIST_DIR/SimpleNESCore.xcframework"
