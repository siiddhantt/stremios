#!/bin/sh
# Pinned, decoder-only libwebp; no downloads and no encoder/animation libraries.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
vendor="$script_dir/../Vendor/libwebp"
out=$1
sdk_name=${2:-iphoneos}
mkdir -p "$out/webp-objects"
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
case "$sdk_name" in iphoneos) minimum=-miphoneos-version-min=12.0 ;; macosx) minimum=-mmacosx-version-min=12.0 ;; *) exit 2 ;; esac
sources="dec/alpha_dec.c dec/buffer_dec.c dec/frame_dec.c dec/idec_dec.c dec/io_dec.c dec/quant_dec.c dec/tree_dec.c dec/vp8_dec.c dec/vp8l_dec.c dec/webp_dec.c
dsp/alpha_processing.c dsp/cpu.c dsp/dec.c dsp/dec_clip_tables.c dsp/filters.c dsp/lossless.c dsp/rescaler.c dsp/upsampling.c dsp/yuv.c
dsp/alpha_processing_neon.c dsp/dec_neon.c dsp/filters_neon.c dsp/lossless_neon.c dsp/rescaler_neon.c dsp/upsampling_neon.c dsp/yuv_neon.c
utils/bit_reader_utils.c utils/color_cache_utils.c utils/filters_utils.c utils/huffman_utils.c utils/palette.c utils/quant_levels_dec_utils.c utils/rescaler_utils.c utils/random_utils.c utils/thread_utils.c utils/utils.c"
for source in $sources; do
  name=$(printf '%s' "$source" | tr / _)
  xcrun --sdk "$sdk_name" clang -arch arm64 -isysroot "$sdk" "$minimum" -O2 -DNDEBUG -DWEBP_USE_THREAD -I "$vendor" -c "$vendor/src/$source" -o "$out/webp-objects/$name.o"
done
xcrun libtool -static -o "$out/libwebpdecoder.a" "$out/webp-objects/"*.o
