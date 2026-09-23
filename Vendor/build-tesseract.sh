#!/bin/bash
#
# Builds the Tesseract and Leptonica static libraries Klik links against, and puts
# them in Vendor/tesseract/ where Config/Vendor.xcconfig expects to find them.
#
# Run by hand, not from Xcode. The result is committed, so a clone builds without
# autotools; re-run this only to change version or flags.
#
#   brew install automake pkg-config     # once
#   Vendor/build-tesseract.sh
#
# Why static: the app is signed with no Team ID and hardened runtime on, so a
# bundled dylib would fail library validation unless the app disabled it. Linking
# the code into the executable puts it under the app's own signature instead, and
# leaves the DMG and Gatekeeper story exactly as it was.
#
# Why no image codecs: Klik hands Tesseract a raw grayscale buffer, so Leptonica
# never reads or writes a file. Turning the codecs off removes the whole
# libpng/jpeg/tiff/webp/zlib dependency chain, which would otherwise link against
# whatever Homebrew has and break on every other Mac.
set -euo pipefail

TESS_TAG=5.5.3
LEPT_VER=1.87.0
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/.build"
OUT="$ROOT/tesseract"
ARCHS=${ARCHS:-"arm64 x86_64"}

export MACOSX_DEPLOYMENT_TARGET=14.0
SDK="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
BUILD_TRIPLE="$(uname -m)-apple-darwin"

for tool in autoconf automake pkg-config libtool; do
    command -v "$tool" >/dev/null || { echo "missing $tool — brew install automake pkg-config"; exit 1; }
done

rm -rf "$WORK"; mkdir -p "$WORK/src"

echo "==> fetching sources"
cd "$WORK/src"
curl -fsSL "https://github.com/DanBloomberg/leptonica/releases/download/$LEPT_VER/leptonica-$LEPT_VER.tar.gz" | tar xz
# A clone, not the release tarball: configure.ac runs `git describe` for the version,
# and the GitHub auto-archive carries no .git.
git clone --quiet --depth 1 --branch "$TESS_TAG" https://github.com/tesseract-ocr/tesseract.git tesseract

for ARCH in $ARCHS; do
    echo "==> building for $ARCH"
    PREFIX="$WORK/prefix-$ARCH"
    FLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2 -g0"
    export CC=clang CXX=clang++
    export CFLAGS="$FLAGS" CXXFLAGS="$FLAGS -std=c++17" LDFLAGS="$FLAGS"
    # Keep Homebrew off the search paths. This Mac has libpng, jpeg-turbo, libtiff,
    # webp, giflib and icu4c under /opt/homebrew; if configure finds any of them the
    # result carries an /opt/homebrew load command that works here and nowhere else.
    export CPPFLAGS=""
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

    rm -rf "$WORK/b-lept-$ARCH"; mkdir -p "$WORK/b-lept-$ARCH"; cd "$WORK/b-lept-$ARCH"
    "$WORK/src/leptonica-$LEPT_VER/configure" \
        --prefix="$PREFIX" --host="$ARCH-apple-darwin" --build="$BUILD_TRIPLE" \
        --disable-shared --enable-static --disable-programs --disable-dependency-tracking \
        --without-zlib --without-libpng --without-jpeg --without-giflib \
        --without-libtiff --without-libwebp --without-libwebpmux --without-libopenjpeg \
        >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null

    cd "$WORK/src/tesseract"
    [ -f configure ] || ./autogen.sh >/dev/null
    rm -rf "$WORK/b-tess-$ARCH"; mkdir -p "$WORK/b-tess-$ARCH"; cd "$WORK/b-tess-$ARCH"
    # --disable-legacy: the packs Klik downloads are LSTM-only, so the old classifier
    #   is dead weight and, if present, invites "legacy engine requested" failures.
    # --disable-openmp: libomp is not in the Xcode toolchain and would be a dylib.
    # --disable-graphics: ScrollView's debug viewer wants a Java process.
    # --disable-tessdata-prefix: stops a build-machine path being baked in.
    "$WORK/src/tesseract/configure" \
        --prefix="$PREFIX" --host="$ARCH-apple-darwin" --build="$BUILD_TRIPLE" \
        --disable-shared --enable-static --disable-openmp --disable-graphics \
        --disable-legacy --disable-doc --disable-tessdata-prefix \
        --disable-dependency-tracking --without-curl --without-archive \
        >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
done

echo "==> assembling $OUT"
rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
FIRST="$(echo $ARCHS | awk '{print $1}')"
cp -R "$WORK/prefix-$FIRST/include/tesseract" "$OUT/include/"
for name in tesseract leptonica; do
    inputs=""
    for arch in $ARCHS; do inputs="$inputs $WORK/prefix-$arch/lib/lib$name.a"; done
    lipo -create $inputs -output "$OUT/lib/lib$name.a"
    strip -S "$OUT/lib/lib$name.a"
done

{
    echo "tesseract $TESS_TAG"
    echo "leptonica $LEPT_VER"
    echo "archs     $ARCHS"
    echo "sdk       $SDK"
    echo "built     $(date -u +%FT%TZ)"
    echo
    shasum -a 256 "$OUT"/lib/*.a
} > "$OUT/VERSIONS.txt"

echo "==> checks"
lipo -info "$OUT/lib/libtesseract.a"
lipo -info "$OUT/lib/libleptonica.a"
echo "-- the CLI's dynamic dependencies (want only libSystem and libc++):"
otool -L "$WORK/prefix-$FIRST/bin/tesseract" | tail -n +2
# Undefined symbol lines only — nm also prints a header line per object file, and
# those carry the very names we are grepping for (gifio.o, webpio.o…).
echo "-- image-codec symbols the libraries must not need (want 0 and 0):"
for lib in libleptonica libtesseract; do
    printf '   %-14s ' "$lib"
    nm -u -arch "$FIRST" "$OUT/lib/$lib.a" 2>/dev/null \
        | grep -E '^[[:space:]]+U ' \
        | grep -cE '_png_|_jpeg_|TIFF|_gif|WebP|_inflate|_deflate' || true
done
ls -lh "$OUT/lib"
