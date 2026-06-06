#!/usr/bin/env bash
# Run a fuzz harness in cold-start and/or seeded modes.
#
# Usage:
#   tools/scripts/fuzz/run.sh <target> [duration_seconds=300] [mode=both]
#
#   target           : harness name without the fuzz_ prefix (e.g. "WPMdlParser")
#   duration_seconds : total wall time across both phases (default 300)
#   mode             : cold | seeded | both (default: both)
#
# Modes:
#   cold    Empty starting corpus. Tests robustness on arbitrary input —
#           catches shallow bugs (header parsing, magic-byte gates, EOF).
#           Findings accumulate in build/fuzz/corpus/<target>/found/.
#   seeded  Starts from real .mdl / .tex inputs in <target>/seed/ (run
#           build-corpus.sh first). Mutates from valid files — catches
#           deeper bugs in version-branched parse paths.
#   both    Splits duration evenly: cold first, then seeded. The cold
#           phase populates found/, which seeded then uses too. Recommended.
#
# Crashes from any phase land in build/fuzz/crashes/ as crash-<sha>; replay
# with: build/fuzz/src/Test/fuzz_<target> build/fuzz/crashes/crash-<sha>

set -euo pipefail

target="${1:?usage: $0 <target> [duration_seconds=300] [mode=both]}"
duration="${2:-300}"
mode="${3:-both}"

build_dir=build/fuzz
binary="$build_dir/src/Test/fuzz_$target"
corpus_root="$build_dir/corpus/$target"
found_dir="$corpus_root/found"
seed_dir="$corpus_root/seed"
crash_dir="$build_dir/crashes"

if [[ ! -x "$binary" ]]; then
    echo "Fuzz harness not built: $binary" >&2
    echo "Build it first:" >&2
    echo "  cmake --build $build_dir --target fuzz_$target" >&2
    exit 1
fi

mkdir -p "$found_dir" "$crash_dir"

common_args=(
    -timeout=5
    -max_len=65536
    -rss_limit_mb=2048
    -malloc_limit_mb=512
    -artifact_prefix="$crash_dir/"
    -print_final_stats=1
)

run_phase() {
    local label="$1"; shift
    local secs="$1"; shift
    echo
    echo "========================================================"
    echo "  Phase: $label  (max ${secs}s)"
    echo "========================================================"
    "$binary" "$@" -max_total_time="$secs" "${common_args[@]}" || true
}

case "$mode" in
    cold)
        run_phase "cold-start" "$duration" "$found_dir"
        ;;
    seeded)
        if [[ ! -d "$seed_dir" || -z "$(ls -A "$seed_dir" 2>/dev/null)" ]]; then
            echo "Seed corpus empty at $seed_dir" >&2
            echo "Run tools/scripts/fuzz/build-corpus.sh first." >&2
            exit 1
        fi
        run_phase "seeded ($(find "$seed_dir" -type f | wc -l) seeds)" \
                  "$duration" "$found_dir" "$seed_dir"
        ;;
    both)
        half=$(( duration / 2 ))
        run_phase "cold-start" "$half" "$found_dir"
        if [[ -d "$seed_dir" && -n "$(ls -A "$seed_dir" 2>/dev/null)" ]]; then
            run_phase "seeded ($(find "$seed_dir" -type f | wc -l) seeds)" \
                      "$half" "$found_dir" "$seed_dir"
        else
            echo
            echo "Skipping seeded phase: seed corpus empty at $seed_dir"
            echo "(Run tools/scripts/fuzz/build-corpus.sh to populate it.)"
        fi
        ;;
    *)
        echo "Unknown mode: $mode (expected cold|seeded|both)" >&2
        exit 1
        ;;
esac

echo
echo "========================================================"
echo "  Summary"
echo "========================================================"
# libFuzzer writes findings under several prefixes:
#   crash-*    sanitizer trip / signal
#   oom-*      RSS or malloc-size limit
#   timeout-*  per-input -timeout exceeded
#   leak-*     LSan-detected leak
artifacts=$(find "$crash_dir" -maxdepth 1 -type f \
    \( -name 'crash-*' -o -name 'oom-*' \
       -o -name 'timeout-*' -o -name 'leak-*' \) 2>/dev/null | wc -l)
found_total=$(find "$found_dir" -type f 2>/dev/null | wc -l)
echo "Corpus inputs (cumulative): $found_total"
echo "Findings (crash/oom/timeout/leak): $artifacts"
if [[ $artifacts -gt 0 ]]; then
    echo
    echo "Findings in $crash_dir:"
    find "$crash_dir" -maxdepth 1 -type f \
        \( -name 'crash-*' -o -name 'oom-*' \
           -o -name 'timeout-*' -o -name 'leak-*' \) \
        -printf '  %f\n' | sort
    exit 1
fi
