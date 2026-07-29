#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
source_icon=${1:-"$project_dir/Resources/AppIcon.png"}
output_icon=${2:-"$project_dir/Resources/AppIcon.icns"}
iconset_dir=$(mktemp -d "${TMPDIR:-/tmp}/nostromo-codex-icon.XXXXXX.iconset")

cleanup_iconset() {
  if [[ -d "$iconset_dir" ]]; then
    find "$iconset_dir" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup_iconset EXIT INT TERM

if [[ ! -f "$source_icon" ]]; then
  print -u2 "App icon source not found: $source_icon"
  exit 1
fi

render_icon() {
  local size=$1
  local filename=$2
  sips --resampleHeightWidth "$size" "$size" "$source_icon" \
    --out "$iconset_dir/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

mkdir -p "${output_icon:h}"
iconutil --convert icns --output "$output_icon" "$iconset_dir"
print "$output_icon"
