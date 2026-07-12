#!/usr/bin/env bash
# Acceptance smoke for the RAM-bounded coverage gate.  Proves (1) the Ninja link
# pool is wired into the COVERAGE build and (2) the full instrumented build's
# peak RSS and the lowest MemAvailable observed during it stay within safe
# bounds — the metric that OOM'd 30 GB boxes.  Slow (~3 min, full instrumented
# build); opt-in, NOT a ctest test.  Run when re-enabling / tuning the gate
# (e.g. before flipping WEK_COVERAGE_IN_GATE=1):
#   WEK_IN_CI=1 tools/scripts/coverage-rss-smoke.sh
set -uo pipefail

cd "$(cd "$(dirname "$0")/../.." && git rev-parse --show-toplevel)"

CEILING_KB="${COVERAGE_RSS_CEILING_KB:-$((12 * 1024 * 1024))}" # 12 GB peak-RSS ceiling
FLOOR_KB="${COVERAGE_MEMAVAIL_FLOOR_KB:-$((4 * 1024 * 1024))}" # 4 GB MemAvailable floor
TIME_BIN=/usr/bin/time

smoke_fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

# 1. Job-pool wiring — a fresh COVERAGE configure must emit the link pool.
cfg=build/cov-smoke-cfg
rm -rf "$cfg"
WEK_IN_CI=1 CC=/usr/bin/clang CXX=/usr/bin/clang++ \
    cmake -B "$cfg" -S tests -G Ninja -DCOVERAGE=ON -DCMAKE_BUILD_TYPE=Debug >/dev/null 2>&1 \
    || smoke_fail "coverage configure failed"
# The pool is declared in CMakeFiles/rules.ninja and referenced on link edges in
# build.ninja; grep the tree so this survives cmake/ninja layout changes.
grep -rq '^pool cov_link_pool' "$cfg" || smoke_fail "cov_link_pool pool not declared"
grep -rq 'pool = cov_link_pool' "$cfg" || smoke_fail "no link edge bound to cov_link_pool"
echo "ok: link pool wired (cov_link_pool)"
rm -rf "$cfg"

[[ -x "$TIME_BIN" ]] || smoke_fail "GNU $TIME_BIN required for peak-RSS measurement"

# 2. Full coverage build under time -v.  time -v only sees the single largest
#    child's RSS, so also sample MemAvailable to catch the aggregate spike the
#    link pool actually bounds.
minfile=$(mktemp)
echo 999999999 > "$minfile"
(
    while :; do
        a=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
        m=$(cat "$minfile")
        [[ -n "$a" && "$a" -lt "$m" ]] && echo "$a" > "$minfile"
        sleep 2
    done
) &
sampler=$!

timefile=$(mktemp)
"$TIME_BIN" -v -o "$timefile" \
    env WEK_COVERAGE_REFRESH=0 tools/scripts/preflight.sh --coverage
rc=$?
kill "$sampler" 2>/dev/null
wait "$sampler" 2>/dev/null

peak=$(awk '/Maximum resident set size/{print $NF}' "$timefile")
min_avail=$(cat "$minfile")
rm -f "$timefile" "$minfile"

echo "coverage leg exit=$rc  peak RSS=${peak} KB  min MemAvailable=${min_avail} KB"
[[ "$rc" -eq 0 ]] || smoke_fail "coverage leg failed (exit $rc)"
[[ -n "$peak" && "$peak" -le "$CEILING_KB" ]] || smoke_fail "peak RSS ${peak} KB > ceiling ${CEILING_KB} KB"
[[ "$min_avail" -ge "$FLOOR_KB" ]] || smoke_fail "MemAvailable fell to ${min_avail} KB < floor ${FLOOR_KB} KB"
echo "SMOKE PASS: coverage build RAM-safe (peak ${peak} KB, MemAvailable floor ${min_avail} KB)"
