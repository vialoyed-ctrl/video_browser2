# Shared by the shipping iOS library and its native regression test.
REMUX_FLAGS=(
  --disable-programs --disable-doc --disable-debug --disable-autodetect --disable-network
  --disable-everything --disable-asm --disable-avdevice --disable-avfilter
  --disable-swscale --disable-swresample --enable-static --disable-shared --enable-pic
  --enable-avformat --enable-avcodec --enable-avutil --enable-small
  --enable-demuxer=mpegts --enable-muxer=mp4 --enable-protocol=file
  --enable-parser=h264,hevc,aac --enable-bsf=aac_adtstoasc,extract_extradata
  --enable-decoder=h264,hevc,aac
)
