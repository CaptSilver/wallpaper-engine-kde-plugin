#!/usr/bin/env bash
# scripts/fuzz/pin-regression.sh — minimise a libFuzzer crash artifact and
# pin it as a regression test fixture.
#
# Usage:
#   scripts/fuzz/pin-regression.sh <target> <crash-artifact> [description]
#
#   target           e.g. WPMdlParser, WPTexImageParser, ...
#   crash-artifact   path to build/sub/fuzz-crashes/crash-<sha> (or any crash file)
#   description      short kebab-case slug (default: derived from sha prefix)
#
# Pipeline:
#   1. cmake --build build/sub --target fuzz_<target>
#   2. fuzz_<target> -minimize_crash=1 -runs=10000 <crash-artifact>
#      writes the minimised file to build/sub/minimized-<sha>.bin
#   3. cp to tests/fixtures/fuzz_regressions/<target>/<description>-<short-sha>.bin
#   4. git add and prompt for commit message.

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

target="${1:?target name required}"
artifact="${2:?crash-artifact path required}"
description="${3:-}"

WORK="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." rev-parse --show-toplevel)"
cd "$WORK"

[[ -f "$artifact" ]] || { echo "artifact not found: $artifact" >&2; exit 1; }

cmake --build build/sub --target "fuzz_$target" >/dev/null
bin="build/sub/src/Test/fuzz_$target"
[[ -x "$bin" ]] || { echo "binary not built: $bin" >&2; exit 1; }

sha="$(sha256sum "$artifact" | cut -c1-8)"
out="build/sub/minimized-$sha.bin"
cp "$artifact" "$out"

# libFuzzer's -minimize_crash=1 rewrites <out> in place across runs.
"$bin" -minimize_crash=1 -runs=10000 "$out" 2>&1 | tail -3

desc="${description:-crash-$sha}"
dest="tests/fixtures/fuzz_regressions/$target/${desc}-${sha}.bin"
mkdir -p "$(dirname "$dest")"
cp "$out" "$dest"
git add "$dest"
echo "pinned: $dest"
echo "stage status: $(git status --porcelain "$dest")"
echo "next: commit with 'fuzz: pin regression for $target — $desc'"
