#!/usr/bin/env bash
# tools/scripts/fuzz/minimize.sh — refresh a checked-in fuzz seed corpus from a hot
# corpus dir produced by a long fuzz session.
#
# Usage:
#   tools/scripts/fuzz/minimize.sh <target> [hot_corpus_dir]
#
#   target           e.g. WPMdlParser, WPTexImageParser, WPSceneParser, ...
#   hot_corpus_dir   default: build/sub/fuzz-corpus-<target>
#
# Pipeline:
#   1. cmake --build build/sub --target fuzz_<target>
#   2. fuzz_<target> -merge=1 -reduce_inputs=1 <tmp-out> tests/fuzz_corpus/<target>/seed/ <hot>
#   3. mv <tmp-out> tests/fuzz_corpus/<target>/seed/
#   4. Report diff (added/removed/total bytes).

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

target="${1:?target name required, e.g. WPMdlParser}"
hot="${2:-build/sub/fuzz-corpus-$target}"
seed="tests/fuzz_corpus/$target/seed"

WORK="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." rev-parse --show-toplevel)"
cd "$WORK"

[[ -d "$hot" ]] || { echo "hot corpus not found: $hot" >&2; exit 1; }

cmake --build build/sub --target "fuzz_$target" >/dev/null
bin="build/sub/src/Test/fuzz_$target"
[[ -x "$bin" ]] || { echo "binary not built: $bin" >&2; exit 1; }

before_count=$(find "$seed" -type f 2>/dev/null | wc -l)
before_bytes=$(du -bs "$seed" 2>/dev/null | cut -f1)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$seed"
"$bin" -merge=1 -reduce_inputs=1 "$tmp" "$seed" "$hot" 2>&1 | tail -5

rm -rf "$seed"
mv "$tmp" "$seed"
trap - EXIT

after_count=$(find "$seed" -type f | wc -l)
after_bytes=$(du -bs "$seed" | cut -f1)
echo "minimize $target: $before_count -> $after_count files, $before_bytes -> $after_bytes bytes"

# Size budget guard.
if [[ "$after_bytes" -gt 204800 ]]; then
    echo "size budget exceeded: $after_bytes > 204800. Re-run with -max_len clamp." >&2
    exit 2
fi
