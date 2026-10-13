#!/usr/bin/env bash
# Self-test for tools/scripts/lib/mutation_rc.sh: how preflight.sh reads each
# tools/scripts/mutation.sh exit code.  A run that measured nothing must never
# read as a pass under MUTATION_FATAL=1, and a skip must never read as a finding.
set -uo pipefail
unset MUTATION_FATAL

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REAL_ROOT/tools/scripts/lib/mutation_rc.sh"
PASS=0
FAIL=0
RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

check() {  # check <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$1"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n        | expected %q, got %q\n' "$RED" "$RESET" "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

echo "== mutation exit-code verdict self-test =="
[[ -f "$LIB" ]] && source "$LIB"
# level <rc> <fatal>: the first field mutation_rc_verdict prints.
level() { MUTATION_FATAL="$2" mutation_rc_verdict "$1" 2>/dev/null | cut -f1; }

check "0 is a pass"                                    ok   "$(level 0 0)"
check "77 (Mull unavailable) is a clean skip"          ok   "$(level 77 1)"
check "79 (past the diff cap) warns, even when fatal"  warn "$(level 79 1)"
check "78 (no measurement) warns when non-fatal"       warn "$(level 78 0)"
check "78 (no measurement) fails when fatal"           fail "$(level 78 1)"
check "2 (bad invocation) warns when non-fatal"        warn "$(level 2 0)"
check "2 (bad invocation) fails when fatal"            fail "$(level 2 1)"
check "1 (new survivors) warns when non-fatal"         warn "$(level 1 0)"
check "1 (new survivors) fails when fatal"             fail "$(level 1 1)"
msg="$(MUTATION_FATAL=1 mutation_rc_verdict 2 2>/dev/null | cut -f2)"
check "a bad invocation is not reported as surviving mutants" 0 "$(grep -c 'surviving' <<<"$msg")"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
