#!/usr/bin/env bash
# Self-test for the pre-push hook's skip-when-already-passed decision.
#
# The hook runs the real tools/scripts/git-hooks/pre-push against a synthetic
# repo whose tools/scripts/preflight.sh is a stub that only counts invocations,
# fed the ref list git would send on stdin.  Pushing the tree that just passed
# the gate must not pay for the gate a second time; anything else (no marker,
# another tree, an expired or weaker marker, a forced rerun) must still run it
# exactly once, detached from the push's stdin.
#
#   tools/scripts/tests/test-pre-push-hook.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail
# preflight.sh runs this from whatever environment the gate was started in; the
# cases pin these themselves, so an inherited value must not change their meaning.
unset MULL_DIFF_BASE MUTATION_FATAL WEK_COVERAGE_IN_GATE COVERAGE_FATAL WEK_GATE_MAX_AGE_H WEK_GATE_FORCE

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$REAL_ROOT/tools/scripts/git-hooks/pre-push"
LIB="$REAL_ROOT/tools/scripts/lib/gate_marker.sh"
PASS=0
FAIL=0
TMPS=()
ZERO=0000000000000000000000000000000000000000

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

cleanup() { for d in "${TMPS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

check() {  # check <name> <ok:0|1> [detail]
    if [[ "$2" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$1"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
        [[ -n "${3:-}" ]] && sed 's/^/        | /' <<<"$3"
        FAIL=$((FAIL + 1))
    fi
}
yes_if() { [[ "$1" == "$2" ]] && echo 1 || echo 0; }

g() { git -c user.email=t@t -c user.name=t "$@"; }

echo "== pre-push hook self-test =="

[[ -f "$LIB" ]] && source "$LIB"

# Synthetic repo carrying the real hook and lib beside a counting stub preflight.
# The stub records how many times it ran and whether its stdin was /dev/null.
make_repo() {
    local root
    root="$(mktemp -d /tmp/wek-hook-XXXXXX)"
    TMPS+=("$root")
    git -C "$root" init -q
    printf 'build\n' > "$root/.gitignore"
    mkdir -p "$root/tools/scripts/git-hooks" "$root/tools/scripts/lib" "$root/build"
    cp "$HOOK" "$root/tools/scripts/git-hooks/pre-push"
    [[ -f "$LIB" ]] && cp "$LIB" "$root/tools/scripts/lib/gate_marker.sh"
    cat > "$root/tools/scripts/preflight.sh" <<'STUB'
#!/usr/bin/env bash
echo run >> "$(dirname "${BASH_SOURCE[0]}")/../../build/gate-runs"
[[ "$(readlink /proc/self/fd/0)" == /dev/null ]] && echo detached >> "$(dirname "${BASH_SOURCE[0]}")/../../build/gate-stdin"
echo "base=${MULL_DIFF_BASE:-}" >> "$(dirname "${BASH_SOURCE[0]}")/../../build/gate-env"
exit "${STUB_GATE_RC:-0}"
STUB
    chmod +x "$root/tools/scripts/preflight.sh" "$root/tools/scripts/git-hooks/pre-push"
    printf 'int a(){return 0;}\n' > "$root/a.cpp"
    g -C "$root" add -A; g -C "$root" commit -q -m one
    printf '%s' "$root"
}

runs() { if [[ -f "$1/build/gate-runs" ]]; then wc -l < "$1/build/gate-runs"; else echo 0; fi; }

# run_hook <root> <stdin-text> [env...]; prints combined output, returns the hook rc.
run_hook() {
    local root="$1" input="$2"; shift 2
    ( cd "$root" && printf '%s' "$input" | env "$@" tools/scripts/git-hooks/pre-push origin url 2>&1 )
}
refline() { printf 'refs/heads/main %s refs/heads/main %s\n' "$1" "$2"; }
record_marker() {  # record_marker <root> -- marker for the current working tree
    ( cd "$1" && read -r p s <<<"$(gate_ids)" && gate_marker_write "$p" "$s" )
}

root="$(make_repo)"
sha="$(git -C "$root" rev-parse HEAD)"

# Baseline: no marker -> gate runs once, detached from the push's stdin.
out="$(run_hook "$root" "$(refline "$sha" "$ZERO")" X=1)"; rc=$?
check "no marker: the gate runs once" "$(yes_if "$(runs "$root")" 1)" "$out"
check "no marker: the gate's stdin is /dev/null" "$(yes_if "$(cat "$root/build/gate-stdin" 2>/dev/null)" detached)"
check "the hook returns the gate's exit status" "$(yes_if "$(run_hook "$root" "$(refline "$sha" "$ZERO")" STUB_GATE_RC=3 >/dev/null; echo $?)" 3)"
rm -f "$root/build/gate-runs"

# A MULL_DIFF_BASE left exported from a pre-commit gate run would point the
# push's mutation leg at an empty diff; the push must measure what it carries.
run_hook "$root" "$(refline "$sha" "$ZERO")" MULL_DIFF_BASE=HEAD >/dev/null
check "the gate a push runs never inherits MULL_DIFF_BASE" "$(yes_if "$(tail -1 "$root/build/gate-env" 2>/dev/null)" "base=")"
rm -f "$root/build/gate-runs"

# Matching marker -> skipped.
record_marker "$root"
out="$(run_hook "$root" "$(refline "$sha" "$ZERO")" X=1)"; rc=$?
check "matching marker: the gate is skipped" "$(yes_if "$(runs "$root")" 0)" "$out"
check "matching marker: the hook exits 0" "$(yes_if "$rc" 0)"
check "matching marker: it says why" "$(yes_if "$(grep -c 'already passed for tree' <<<"$out")" 1)" "$out"

# WEK_GATE_FORCE=1 reruns.
run_hook "$root" "$(refline "$sha" "$ZERO")" WEK_GATE_FORCE=1 >/dev/null
check "WEK_GATE_FORCE=1 runs the gate despite a matching marker" "$(yes_if "$(runs "$root")" 1)"
rm -f "$root/build/gate-runs"

# A different commit (different tree) than the marker -> runs.
printf 'int a(){return 1;}\n' > "$root/a.cpp"; g -C "$root" commit -q -am two
sha2="$(git -C "$root" rev-parse HEAD)"
run_hook "$root" "$(refline "$sha2" "$ZERO")" X=1 >/dev/null
check "pushing a commit whose tree has no marker runs the gate" "$(yes_if "$(runs "$root")" 1)"
rm -f "$root/build/gate-runs"

# The marker was taken on a dirty tree: the pushed HEAD is not that tree.
printf 'int a(){return 2;}\n' > "$root/a.cpp"
record_marker "$root"
git -C "$root" checkout -q -- a.cpp
run_hook "$root" "$(refline "$sha2" "$ZERO")" X=1 >/dev/null
check "a marker taken on uncommitted edits does not cover the committed HEAD" "$(yes_if "$(runs "$root")" 1)"
rm -f "$root/build/gate-runs"

# Multi-ref push: one covered ref plus one uncovered ref must run the gate.
record_marker "$root"
printf 'int a(){return 3;}\n' > "$root/a.cpp"; g -C "$root" commit -q -am three
sha3="$(git -C "$root" rev-parse HEAD)"
git -C "$root" reset -q --hard "$sha2"
input="$(refline "$sha2" "$ZERO"; refline "$sha3" "$ZERO")"
run_hook "$root" "$input" X=1 >/dev/null
check "two refs, one without a marker: the gate runs" "$(yes_if "$(runs "$root")" 1)"
rm -f "$root/build/gate-runs"
input="$(refline "$sha2" "$ZERO"; printf 'refs/heads/other %s refs/heads/other %s\n' "$sha2" "$ZERO")"
run_hook "$root" "$input" X=1 >/dev/null
check "two refs, both covered: the gate is skipped" "$(yes_if "$(runs "$root")" 0)"

# Expired marker, and a marker weaker than the current strictness.
run_hook "$root" "$(refline "$sha2" "$ZERO")" WEK_GATE_MAX_AGE_H=0 >/dev/null
check "an expired marker runs the gate" "$(yes_if "$(runs "$root")" 1)"
rm -f "$root/build/gate-runs"
run_hook "$root" "$(refline "$sha2" "$ZERO")" MUTATION_FATAL=1 >/dev/null
check "MUTATION_FATAL=1 against a non-fatal marker runs the gate" "$(yes_if "$(runs "$root")" 1)"
rm -f "$root/build/gate-runs"

# Deleting a remote branch pushes nothing to verify.
out="$(run_hook "$root" "$(printf '(delete) %s refs/heads/old %s\n' "$ZERO" "$sha")" X=1)"; rc=$?
check "a delete push exits 0 without running the gate" "$(yes_if "$rc$(runs "$root")" 00)" "$out"

# Empty ref list (nothing to push) is not evidence of a pass: stay conservative.
run_hook "$root" "" X=1 >/dev/null
check "an empty ref list still runs the gate" "$(yes_if "$(runs "$root")" 1)"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
