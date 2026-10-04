#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=8.0.1
BUILD="$ROOT/build/ffmpeg-ios"
PREFIX="$ROOT/ios/MediaRemux/Vendor"
mkdir -p "$BUILD" "$PREFIX"
curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$BUILD/source.tar.xz"
tar -xf "$BUILD/source.tar.xz" -C "$BUILD"
cd "$BUILD/ffmpeg-$VERSION"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
./configure --prefix="$PREFIX" --enable-cross-compile --target-os=darwin --arch=arm64   --cc="$(xcrun --sdk iphoneos --find clang)" --sysroot="$SDK"   --extra-cflags="-arch arm64 -miphoneos-version-min=16.0"   --extra-ldflags="-arch arm64 -miphoneos-version-min=16.0"   --disable-programs --disable-doc --disable-debug --disable-autodetect --disable-network   --disable-everything --disable-asm --disable-avdevice --disable-avfilter   --disable-swscale --disable-swresample --enable-static --disable-shared --enable-pic   --enable-avformat --enable-avcodec --enable-avutil --enable-small   --enable-demuxer=mpegts --enable-muxer=mp4 --enable-protocol=file   --enable-parser=h264,hevc,aac --enable-bsf=aac_adtstoasc,extract_extradata
make -j 3
make install
cp COPYING.LGPLv2.1 "$PREFIX/LICENSE"
cp "$BUILD/source.tar.xz" "$PREFIX/ffmpeg-$VERSION-source.tar.xz"
