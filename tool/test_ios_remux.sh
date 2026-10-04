#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/remux-native-test"
mkdir -p "$BUILD"
curl --fail --location --retry 3 https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz -o "$BUILD/source.tar.xz"
tar -xf "$BUILD/source.tar.xz" -C "$BUILD"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=25 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -ac 2 -f mpegts "$BUILD/av.ts"
ffmpeg -hide_banner -loglevel error -i "$BUILD/av.ts" -an -c:v copy -f mpegts "$BUILD/silent.ts"
cat "$BUILD/av.ts" "$BUILD/av.ts" > "$BUILD/restarted.ts"
source "$ROOT/tool/remux_ffmpeg_flags.sh"
cd "$BUILD/ffmpeg-8.0.1"
# Reproduce the old library configuration before testing the corrected one.
./configure --prefix="$BUILD/old" "${REMUX_FLAGS[@]}" --disable-decoders
make -j 3 >/dev/null
make install >/dev/null
link_test() {
  cc -I"$1/include" -I"$ROOT/ios/MediaRemux/Sources" "$ROOT/tool/remux_test_main.c" "$ROOT/ios/MediaRemux/Sources/VBMediaRemux.c" -L"$1/lib" -lavformat -lavcodec -lavutil -lm -lpthread -lz -o "$2"
}
link_test "$BUILD/old" "$BUILD/old-remux"
if "$BUILD/old-remux" "$BUILD/av.ts" "$BUILD/old.mp4"; then
  echo "Baseline remux succeeded for the generated fixture"
else
  echo "Reproduced legacy remux failure with H.264 + AAC"
fi
./configure --prefix="$BUILD/new" "${REMUX_FLAGS[@]}"
make -j 3 >/dev/null
make install >/dev/null
link_test "$BUILD/new" "$BUILD/remux"
for name in av silent restarted; do
  "$BUILD/remux" "$BUILD/$name.ts" "$BUILD/$name.mp4"
  ffprobe -v error -show_entries stream=codec_name,width,height,sample_rate,channels -of json "$BUILD/$name.mp4"
  ffmpeg -hide_banner -loglevel error -xerror -i "$BUILD/$name.mp4" -f null -
done
printf 'not a video' > "$BUILD/broken.ts"
if "$BUILD/remux" "$BUILD/broken.ts" "$BUILD/broken.mp4"; then exit 1; fi
test -f "$BUILD/broken.ts"
test ! -f "$BUILD/broken.mp4"
echo "Native remux regression tests passed"

if [[ -n "${REMUX_TEST_PAGE:-}" ]]; then
  cd "$ROOT"
  python3 tool/fetch_remux_fixture.py
  "$BUILD/remux" "$BUILD/source.ts" "$BUILD/source.mp4"
  ffprobe -v error -show_entries stream=codec_name,width,height,sample_rate,channels -of json "$BUILD/source.mp4"
  ffmpeg -hide_banner -loglevel error -xerror -i "$BUILD/source.mp4" -f null -
  echo "Reported source video remux and decode passed"
fi
