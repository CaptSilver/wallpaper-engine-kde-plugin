#!/usr/bin/env bash
# Self-test for the coverage gate wrapper's decision logic.
#
# preflight.sh's in-gate coverage wrapper used to re-derive its own pass/fail
# verdict from COVERAGE_FATAL after already running the nested --coverage leg,
# instead of trusting the exit code that leg had already computed from the same
# variable.  That produced two wrong answers: a false "no regression" when the
# leg had tolerated one, and a silent wave-through of a build that had actually
# failed to configure.  This exercises lib/coverage_gate.sh's run_coverage_gate
# against stub legs standing in for each of those cases -- no cmake, no build,
# runs in a fraction of a second.
#
#   tools/scripts/tests/test-coverage-gate.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE_LIB="$REAL_ROOT/tools/scripts/lib/coverage_gate.sh"
PASS=0
FAIL=0

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

# run_case <fail-def-and-stub-and-call...>
#   Runs the given body in a subshell so a fail() call's `exit 1` can't kill
#   this test runner -- the same trick test-mutation-gate.sh uses.  The body
#   defines its own fail() matching preflight's real one, sources the gate lib
#   under test, then calls run_coverage_gate.
run_case() {
    ( eval "$1" ) 2>&1
}

check() {  # check <name> <actual-rc> <expected-rc> <output> [must-contain] [must-not-contain]
    local name="$1" rc="$2" want="$3" out="$4" needle="${5:-}" neg_needle="${6:-}"
    local ok=1
    [[ "$rc" == "$want" ]] || ok=0
    if [[ -n "$needle" ]] && ! grep -qiF -- "$needle" <<<"$out"; then ok=0; fi
    if [[ -n "$neg_needle" ]] && grep -qiF -- "$neg_needle" <<<"$out"; then ok=0; fi
    if [[ "$ok" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        printf '        expected rc=%s got rc=%s' "$want" "$rc"
        [[ -n "$needle" ]] && printf ', expected output to contain: %s' "$needle"
        [[ -n "$neg_needle" ]] && printf ', expected output NOT to contain: %s' "$neg_needle"
        printf '\n'
        sed 's/^/        | /' <<<"$out" | tail -15
        FAIL=$((FAIL + 1))
    fi
}

echo "== coverage gate self-test =="

# 1. A leg that passes cleanly must not be reported as a failure, and the
#    wrapper must not print anything of its own -- the leg's own stdout is the
#    only source of truth for what happened.
out="$(run_case '
    fail() { echo "FAIL-CALLED: $*"; exit 1; }
    source "'"$GATE_LIB"'"
    stub_pass() { echo "leg: coverage at/above baseline"; return 0; }
    run_coverage_gate stub_pass
')"; rc=$?
check "coverage_gate__leg_passes_prints_nothing_of_its_own" "$rc" 0 "$out" "" "FAIL-CALLED"

# 2. The regression that started this: a leg that tolerated a regression
#    (COVERAGE_FATAL=0, still returns 0) must not be laundered into a claim
#    that there was no regression.  Restoring the old
#    `if [[ "$crc" == "0" ]]; then ok "...no regression..."` branch re-breaks
#    this -- crc=0 from this stub still hits it.
out="$(run_case '
    fail() { echo "FAIL-CALLED: $*"; exit 1; }
    source "'"$GATE_LIB"'"
    stub_tolerated_regression() {
        echo "leg: coverage regression vs baseline (tolerance 0.5pp): ..."
        echo "leg: non-fatal -- ..."
        return 0
    }
    run_coverage_gate stub_tolerated_regression
')"; rc=$?
check "coverage_gate__tolerated_regression_is_not_reported_as_no_regression" "$rc" 0 "$out" "" "no regression"

# 3. A hard failure (configure/build error) inside the leg must be fatal
#    regardless of COVERAGE_FATAL -- that variable only ever gated the leg's
#    own regression-tolerance decision, never its build-failure fail() calls.
#    Restoring the old `elif [[ "${COVERAGE_FATAL:-1}" == "1" ]] ... else warn`
#    structure re-breaks this: with COVERAGE_FATAL=0 and crc=1, that elif is
#    false and it falls through to warn, never calling fail.
out="$(run_case '
    fail() { echo "FAIL-CALLED: $*"; exit 1; }
    source "'"$GATE_LIB"'"
    export COVERAGE_FATAL=0
    stub_hard_failure() { echo "leg: FAIL: coverage configure failed (parent)"; return 1; }
    run_coverage_gate stub_hard_failure
')"; rc=$?
check "coverage_gate__hard_failure_is_fatal_even_when_COVERAGE_FATAL_is_0" "$rc" 1 "$out" "FAIL-CALLED"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
