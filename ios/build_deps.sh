#!/bin/bash
# Builds the two libraries OpenUG2 needs, as static iOS libraries, into ios/deps/out/<sdk>/:
#   SDL2    (windowing, GLES context, touch, audio, game controllers) -- SDL's own "Static Library-iOS" target
#   libpng  (UI glyph/button images) -- CMake; zlib comes from the iOS SDK
# SHA-256 (the only OpenSSL use) is served by CommonCrypto through ios/compat, so there is no libcrypto.
#
# Usage:  ./build_deps.sh                       device (arm64)
#         SDK=iphonesimulator ./build_deps.sh   Apple-silicon simulator
# Needs:  Xcode command line tools, cmake, git (brew install cmake)
set -euo pipefail
cd "$(dirname "$0")"

SDK=${SDK:-iphoneos}
DEPLOY=${DEPLOY:-13.0}
SDL_TAG=${SDL_TAG:-release-2.30.12}
PNG_TAG=${PNG_TAG:-v1.6.43}

case "$SDK" in iphoneos|iphonesimulator) ;; *) echo "SDK must be iphoneos or iphonesimulator" >&2; exit 1;; esac
command -v cmake >/dev/null || { echo "cmake not found: brew install cmake" >&2; exit 1; }

ROOT=$PWD
SRC=$ROOT/deps/src
BUILD=$ROOT/deps/build
OUT=$ROOT/deps/out/$SDK
SDKPATH=$(xcrun --sdk "$SDK" --show-sdk-path)
mkdir -p "$SRC" "$BUILD" "$OUT/lib" "$OUT/include"

fetch() {   # name url tag
    [ -d "$SRC/$1/.git" ] || git clone --depth 1 --branch "$3" "$2" "$SRC/$1"
}

echo "== SDL2 ($SDL_TAG) for $SDK"
fetch SDL https://github.com/libsdl-org/SDL.git "$SDL_TAG"
xcodebuild -project "$SRC/SDL/Xcode/SDL/SDL.xcodeproj" -target "Static Library-iOS" \
    -configuration Release -sdk "$SDK" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOY" BUILD_DIR="$BUILD/sdl-$SDK" \
    CODE_SIGNING_ALLOWED=NO build | tail -n 5
LIBSDL=$(find "$BUILD/sdl-$SDK" -name libSDL2.a | head -n 1)
[ -n "$LIBSDL" ] || { echo "libSDL2.a was not produced" >&2; exit 1; }
cp "$LIBSDL" "$OUT/lib/libSDL2.a"

echo "== libpng ($PNG_TAG) for $SDK"
fetch libpng https://github.com/pnggroup/libpng.git "$PNG_TAG"
cmake -S "$SRC/libpng" -B "$BUILD/png-$SDK" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_INSTALL_PREFIX="$OUT" \
    -DZLIB_LIBRARY="$SDKPATH/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$SDKPATH/usr/include" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_EXECUTABLES=OFF -DPNG_FRAMEWORK=OFF
cmake --build "$BUILD/png-$SDK" --config Release --target install -j 4
# the static library is installed as libpng16.a with a libpng.a alias; make sure the name we link exists
[ -f "$OUT/lib/libpng16.a" ] || cp "$(find "$OUT/lib" -name 'libpng*.a' | head -n 1)" "$OUT/lib/libpng16.a"

echo "== done: $OUT"
ls -la "$OUT/lib"
