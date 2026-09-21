#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

source_png="${1:-$REPO_ROOT/Assets/AppIcon.png}"
output_dir="$(absolute_new_directory "${2:-$REPO_ROOT/artifacts/icons/$(date -u +%Y%m%dT%H%M%SZ)}")"
[[ -f "$source_png" ]] || fail "Missing source icon: $source_png"
require_new_path "$output_dir"
mkdir -p "$output_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_png" --out "$output_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$source_png" --out "$output_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$output_dir/AppIcon.iconset" -o "$output_dir/AppIcon.icns"
print "Built macOS icon: $output_dir/AppIcon.icns"
