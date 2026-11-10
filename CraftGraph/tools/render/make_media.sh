#!/bin/sh
# Turns the SVG frames from scenes.lua into the pictures the docs use.
#   tools/render/make_media.sh <frames folder> <output folder>
# Needs rsvg-convert and ffmpeg. Stills become PNG, each sequence a GIF,
# and the tour also an MP4.
set -eu
src=$1
out=$2
mkdir -p "$out"
find "$src" -name '*.svg' | while read -r f; do
  png="${f%.svg}.png"
  [ "$png" -nt "$f" ] || rsvg-convert "$f" -o "$png"
done
cp "$src"/stills/*.png "$out"/
for dir in "$src"/*/; do
  name=$(basename "$dir")
  [ -f "$dir/frames.txt" ] || continue
  width=900
  [ "$name" = tour ] && width=1100
  [ "$name" = graph ] && width=1100
  [ "$name" = wave ] && width=1100
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$dir/frames.txt" \
    -vf "fps=12,scale='min($width,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    "$out/$name.gif"
  if [ "$name" = tour ]; then
    ffmpeg -loglevel error -y -f concat -safe 0 -i "$dir/frames.txt" \
      -vf "fps=24,scale=1280:-2,format=yuv420p" -c:v libx264 -crf 24 -movflags +faststart "$out/tour.mp4"
  fi
done
ls -la "$out"
