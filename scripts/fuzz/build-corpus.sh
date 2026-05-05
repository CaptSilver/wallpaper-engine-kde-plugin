#!/usr/bin/env bash
# Extract .mdl and .tex files from installed Wallpaper Engine workshop content
# into per-target seed corpora. Pulls from loose files under the workshop dir
# and from .pkg archives via wp-pkg.
#
# Usage: scripts/fuzz/build-corpus.sh [build_dir]
#
# Env overrides:
#   WP_WORKSHOP=<path>   Workshop root (default: ~/.local/share/Steam/...)
#   MAX_MDL_BYTES=<n>    Skip .mdl files larger than this (default: 1M)
#   MAX_TEX_BYTES=<n>    Skip .tex files larger than this (default: 10M)

set -euo pipefail

build_dir="${1:-build/fuzz}"
workshop="${WP_WORKSHOP:-$HOME/.local/share/Steam/steamapps/workshop/content/431960}"
max_mdl="${MAX_MDL_BYTES:-1048576}"
max_tex="${MAX_TEX_BYTES:-10485760}"

mdl_seed="$build_dir/corpus/WPMdlParser/seed"
tex_seed="$build_dir/corpus/WPTexImageParser/seed"
wp_pkg="$build_dir/tools/wp-pkg"

if [[ ! -d "$workshop" ]]; then
    echo "Workshop directory not found: $workshop" >&2
    echo "Set WP_WORKSHOP=<path> if your install is elsewhere." >&2
    exit 1
fi

if [[ ! -x "$wp_pkg" ]]; then
    echo "wp-pkg binary not found at $wp_pkg" >&2
    echo "Build it first: cmake --build $build_dir --target wp-pkg" >&2
    exit 1
fi

mkdir -p "$mdl_seed" "$tex_seed"

echo "Workshop: $workshop"
echo "Output:   $build_dir/corpus/{WPMdlParser,WPTexImageParser}/seed/"

# 1. Loose files in workshop dir (uncompressed wallpapers store .mdl/.tex
#    directly alongside scene.json).
echo
echo "[1/2] Scanning loose files..."
find "$workshop" -type f -name "*.mdl" -size "-${max_mdl}c" \
    -exec sh -c 'cp -n "$1" "$2/$(stat -c %i "$1").mdl"' _ {} "$mdl_seed" \; 2>/dev/null
find "$workshop" -type f -name "*.tex" -size "-${max_tex}c" \
    -exec sh -c 'cp -n "$1" "$2/$(stat -c %i "$1").tex"' _ {} "$tex_seed" \; 2>/dev/null

# 2. Embedded in scene.pkg archives (compressed wallpapers).
echo "[2/2] Extracting from scene.pkg archives..."
tmpdir=$(mktemp -d -t wek-fuzz-corpus-XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

for pkg in "$workshop"/*/scene.pkg; do
    [[ -f "$pkg" ]] || continue
    wid=$(basename "$(dirname "$pkg")")
    pkg_out="$tmpdir/$wid"
    mkdir -p "$pkg_out"
    "$wp_pkg" extract "$pkg" "$pkg_out" >/dev/null 2>&1 || continue
    find "$pkg_out" -type f -name "*.mdl" -size "-${max_mdl}c" \
        -exec sh -c 'cp -n "$1" "$2/${3}_$(basename "$1")"' _ {} "$mdl_seed" "$wid" \; 2>/dev/null
    find "$pkg_out" -type f -name "*.tex" -size "-${max_tex}c" \
        -exec sh -c 'cp -n "$1" "$2/${3}_$(basename "$1")"' _ {} "$tex_seed" "$wid" \; 2>/dev/null
done

mdl_count=$(find "$mdl_seed" -type f | wc -l)
tex_count=$(find "$tex_seed" -type f | wc -l)
echo
echo "Corpus built:"
printf "  WPMdlParser:      %4d inputs in %s\n" "$mdl_count" "$mdl_seed"
printf "  WPTexImageParser: %4d inputs in %s\n" "$tex_count" "$tex_seed"
