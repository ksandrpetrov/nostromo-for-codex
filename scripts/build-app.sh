#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${1:-release}
build_dir="$project_dir/.build/arm64-apple-macosx/$configuration"
app_dir="$project_dir/dist/Nostromo Codex.app"
staging_app_dir="$project_dir/dist/.Nostromo Codex.app.staging.$$"
contents_dir="$staging_app_dir/Contents"
module_cache_root=${NOSTROMO_BUILD_CACHE_DIR:-${TMPDIR:-/tmp}/nostromo-codex-build-cache}
mkdir -p "$module_cache_root/clang" "$module_cache_root/swift"
export CLANG_MODULE_CACHE_PATH="$module_cache_root/clang"
export SWIFT_MODULECACHE_PATH="$module_cache_root/swift"

cleanup_staging() {
  if [[ -d "$staging_app_dir" ]]; then
    find "$staging_app_dir" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup_staging EXIT INT TERM

cd "$project_dir"
swift build --disable-sandbox -c "$configuration" --arch arm64

if [[ ! -x "$build_dir/NostromoCodex" ]]; then
  print -u2 "Expected executable not found: $build_dir/NostromoCodex"
  exit 1
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$build_dir/NostromoCodex" "$contents_dir/MacOS/NostromoCodex"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs" \
  "$contents_dir/Resources/chatgpt-preload.cjs"
"$project_dir/scripts/build-icon.sh" \
  "$project_dir/Resources/AppIcon.png" \
  "$contents_dir/Resources/AppIcon.icns"

"$project_dir/scripts/sign-app.sh" "$staging_app_dir"

# Never destroy the last launchable bundle because compilation or signing
# failed. Replacement happens only after the staged app passes strict
# signature verification.
if [[ -e "$app_dir" ]]; then
  find "$app_dir" -depth -delete
fi
mv "$staging_app_dir" "$app_dir"
trap - EXIT INT TERM
print "$app_dir"
