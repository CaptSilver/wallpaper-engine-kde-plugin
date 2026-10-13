#!/usr/bin/env bash
# Self-test for the preflight pass marker (tools/scripts/lib/gate_marker.sh).
#
# The marker lets the pre-push hook skip a gate that already passed for the exact
# tree being pushed.  That is only safe if the id it keys on follows the WORKING
# tree (a plain HEAD^{tree} ignores uncommitted edits, so a gate that passed on a
# dirty tree would green-light a different commit) and if the marker is refused
# for any run that did not measure everything (fuzz skipped, mutation unmeasured).
# Each case pins one of those decisions against a synthetic repo; nothing here
# builds anything.
#
#   tools/scripts/tests/test-gate-marker.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REAL_ROOT/tools/scripts/lib/gate_marker.sh"
PREFLIGHT="$REAL_ROOT/tools/scripts/preflight.sh"
PASS=0
FAIL=0
TMPS=()

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

echo "== gate marker self-test =="

if [[ ! -f "$LIB" ]]; then
    check "tools/scripts/lib/gate_marker.sh exists" 0 "missing: $LIB"
    printf '%s0 passed, %d failed%s\n' "$RED" "$FAIL" "$RESET"
    exit 1
fi
# shellcheck source=../lib/gate_marker.sh
source "$LIB"

g() { git -c user.email=t@t -c user.name=t "$@"; }

# A parent repo with src/backend_scene registered as a real nested repo (gitlink),
# the shape the gate sees.  Printed path is the parent root.
make_repo() {
    local root
    root="$(mktemp -d /tmp/wek-gatemark-XXXXXX)"
    TMPS+=("$root")
    git -C "$root" init -q
    printf 'build\n' > "$root/.gitignore"
    mkdir -p "$root/src/backend_scene" "$root/tools/scripts" "$root/build"
    git -C "$root/src/backend_scene" init -q
    printf 'build\n' > "$root/src/backend_scene/.gitignore"
    printf 'int s(){return 0;}\n' > "$root/src/backend_scene/s.cpp"
    g -C "$root/src/backend_scene" add -A
    g -C "$root/src/backend_scene" commit -q -m sub
    printf 'int a(){return 0;}\n' > "$root/a.cpp"
    printf '#!/bin/sh\n' > "$root/tools/scripts/mutation.sh"
    g -C "$root" add -A 2>/dev/null
    g -C "$root" commit -q -m base
    printf '%s' "$root"
}

ids() { ( cd "$1" && gate_ids ); }

# 1. Clean tree: the id of the working tree is the id of HEAD, so a marker taken
#    on it matches the commit that gets pushed.
root="$(make_repo)"
read -r p s <<<"$(ids "$root")"
head_tree="$(git -C "$root" rev-parse 'HEAD^{tree}')"
check "a clean working tree has the id of HEAD's tree" "$(yes_if "$p" "$head_tree")" "gate_ids parent=$p head=$head_tree"
( cd "$root" && gate_marker_write "$p" "$s" )
( cd "$root" && gate_marker_matches HEAD ); rc=$?
check "a marker written for a clean tree matches HEAD" "$(yes_if "$rc" 0)"

# 2. The trap the temp-index approach exists for: HEAD^{tree} does not move when a
#    tracked file is edited but not committed.
printf 'int a(){return 1;}\n' > "$root/a.cpp"
read -r p2 s2 <<<"$(ids "$root")"
check "an uncommitted edit to a tracked file changes the id" "$(yes_if "$([[ "$p2" != "$p" ]] && echo y)" y)"
( cd "$root" && gate_marker_matches HEAD ) ; rc=$?
check "the old marker still matches the unchanged HEAD commit (the hook compares commits)" "$(yes_if "$rc" 0)"
root_d="$(make_repo)"
printf 'int a(){return 1;}\n' > "$root_d/a.cpp"
read -r pd sd <<<"$(ids "$root_d")"
( cd "$root_d" && gate_marker_write "$pd" "$sd" && gate_marker_matches HEAD ); rc=$?
check "a marker taken on a dirty tree does not match the HEAD commit" "$(yes_if "$rc" 1)"
git -C "$root" checkout -q -- a.cpp 2>/dev/null || printf 'int a(){return 0;}\n' > "$root/a.cpp"

# 3. Untracked files count, ignored ones do not.
printf 'x\n' > "$root/new.cpp"
read -r p3 _ <<<"$(ids "$root")"
check "an untracked, non-ignored file changes the id" "$(yes_if "$([[ "$p3" != "$p" ]] && echo y)" y)"
rm "$root/new.cpp"
printf 'junk\n' > "$root/build/artifact.o"
read -r p4 _ <<<"$(ids "$root")"
check "a file under an ignored build/ does not change the id" "$(yes_if "$p4" "$p")"

# 4. A dirty file inside the submodule leaves the parent tree alone (only the
#    gitlink is in it), so the submodule needs an id of its own.
printf 'int s(){return 9;}\n' > "$root/src/backend_scene/s.cpp"
read -r p5 s5 <<<"$(ids "$root")"
check "a dirty submodule file leaves the parent id unchanged" "$(yes_if "$p5" "$p")"
check "a dirty submodule file changes the submodule id" "$(yes_if "$([[ "$s5" != "$s" ]] && echo y)" y)"
git -C "$root/src/backend_scene" checkout -q -- s.cpp

# 5. A dirty third_party checkout inside the submodule is invisible to both ids
#    (only its gitlink is hashed), so the writer has to refuse outright.
dep="$(mktemp -d /tmp/wek-gatemark-dep-XXXXXX)"; TMPS+=("$dep")
git -C "$dep" init -q; printf 'd\n' > "$dep/d.txt"; g -C "$dep" add -A; g -C "$dep" commit -q -m dep
mkdir -p "$root/src/backend_scene/third_party"
g -C "$root/src/backend_scene" -c protocol.file.allow=always submodule add -q "$dep" third_party/dep 2>/dev/null
g -C "$root/src/backend_scene" commit -q -m add-dep
g -C "$root" add -A 2>/dev/null; g -C "$root" commit -q -m bump
out="$( cd "$root" && gate_ids 2>&1 )"; rc=$?
check "a clean nested submodule is accepted" "$(yes_if "$rc" 0)" "$out"
printf 'dirty\n' >> "$root/src/backend_scene/third_party/dep/d.txt"
out="$( cd "$root" && gate_ids 2>&1 )"; rc=$?
check "a dirty nested submodule makes gate_ids refuse" "$(yes_if "$rc" 1)" "$out"
git -C "$root/src/backend_scene/third_party/dep" checkout -q -- d.txt

# 6. The gate's own scripts live in the parent tree, so editing one invalidates
#    the marker without a separate hash.
read -r p6 s6 <<<"$(ids "$root")"
( cd "$root" && gate_marker_write "$p6" "$s6" )
printf '# changed\n' >> "$root/tools/scripts/mutation.sh"
read -r p7 _ <<<"$(ids "$root")"
check "editing a gate script changes the id" "$(yes_if "$([[ "$p7" != "$p6" ]] && echo y)" y)"
git -C "$root" checkout -q -- tools/scripts/mutation.sh

# 7. Computing ids must leave the repository exactly as it was.
snap() {
    ( cd "$1"
      git status --porcelain; git stash list; git rev-parse HEAD
      git ls-files --stage | sha256sum; sha256sum .git/index )
}
printf 'wip\n' > "$root/wip.cpp"
before="$(snap "$root")"
( cd "$root" && gate_ids >/dev/null && gate_marker_matches HEAD; true )
after="$(snap "$root")"
check "gate_ids / gate_marker_matches leave status, stash, HEAD and the real index untouched" "$(yes_if "$after" "$before")" "$(diff <(echo "$before") <(echo "$after"))"
rm "$root/wip.cpp"

# 8. should_write: only a complete full-mode run earns a marker.
sw() { ( gate_marker_should_write "$@" ) ; echo $?; }
check "full run, fuzz ran clean, mutation rc 0 -> marker"             "$(yes_if "$(sw full 0 0 0)" 0)"
check "full run, mutation runner unavailable (rc 77) -> marker"       "$(yes_if "$(sw full 0 0 77)" 0)"
check "--no-fuzz run -> no marker"                                    "$(yes_if "$(sw full 1 0 0)" 1)"
check "fuzz degraded (binary missing or short run) -> no marker"      "$(yes_if "$(sw full 0 1 0)" 1)"
check "mutation produced no measurement (rc 78) -> no marker"         "$(yes_if "$(sw full 0 0 78)" 1)"
check "mutation skipped past the diff cap (rc 79) -> no marker"       "$(yes_if "$(sw full 0 0 79)" 1)"
check "mutation found new survivors (rc 1) -> no marker"              "$(yes_if "$(sw full 0 0 1)" 1)"
check "non-full mode (--no-build) -> no marker"                       "$(yes_if "$(sw test-only 0 0 0)" 1)"

# 9. Matching rules the hook relies on: age, strictness, ring.
root="$(make_repo)"
read -r p s <<<"$(ids "$root")"
( cd "$root" && MUTATION_FATAL=0 gate_marker_write "$p" "$s" )
( cd "$root" && MUTATION_FATAL=1 gate_marker_matches HEAD ); rc=$?
check "a marker from a non-fatal-mutation run does not satisfy MUTATION_FATAL=1" "$(yes_if "$rc" 1)"
( cd "$root" && WEK_COVERAGE_IN_GATE=1 gate_marker_matches HEAD ); rc=$?
check "a marker from a run without the coverage leg does not satisfy WEK_COVERAGE_IN_GATE=1" "$(yes_if "$rc" 1)"
( cd "$root" && WEK_COVERAGE_IN_GATE=1 COVERAGE_FATAL=0 gate_marker_write "$p" "$s" )
( cd "$root" && WEK_COVERAGE_IN_GATE=1 gate_marker_matches HEAD ); rc=$?
check "a marker from an advisory coverage run (COVERAGE_FATAL=0) does not satisfy a fatal one" "$(yes_if "$rc" 1)"
( cd "$root" && WEK_COVERAGE_IN_GATE=1 COVERAGE_FATAL=0 gate_marker_matches HEAD ); rc=$?
check "the same advisory marker satisfies an advisory push" "$(yes_if "$rc" 0)"
( cd "$root" && MUTATION_FATAL=0 gate_marker_write "$p" "$s" )
( cd "$root" && WEK_GATE_MAX_AGE_H=0 gate_marker_matches HEAD ); rc=$?
check "an expired marker does not match" "$(yes_if "$rc" 1)"
( cd "$root" && MUTATION_FATAL=1 gate_marker_write "$p" "$s" && MUTATION_FATAL=0 gate_marker_matches HEAD ); rc=$?
check "a stricter-than-needed marker satisfies a looser push" "$(yes_if "$rc" 0)"

# Ring: an older tree stays matchable after a newer one is recorded.
c1="$(git -C "$root" rev-parse HEAD)"
printf 'int a(){return 2;}\n' > "$root/a.cpp"; g -C "$root" commit -q -am second
read -r pb sb <<<"$(ids "$root")"
( cd "$root" && gate_marker_write "$pb" "$sb" && gate_marker_matches HEAD ); rc=$?
check "the newest marker matches its own commit" "$(yes_if "$rc" 0)"
( cd "$root" && gate_marker_matches "$c1" ); rc=$?
check "an earlier recorded tree still matches its commit (ring, not a single slot)" "$(yes_if "$rc" 0)"
printf 'int a(){return 3;}\n' > "$root/a.cpp"; g -C "$root" commit -q -am third
( cd "$root" && gate_marker_matches HEAD ); rc=$?
check "a commit with no recorded tree does not match" "$(yes_if "$rc" 1)"

# 10. A submodule commit the clone does not have cannot be compared: run the gate.
root2="$(make_repo)"
read -r p s <<<"$(ids "$root2")"
( cd "$root2" && gate_marker_write "$p" "$s" )
fake_tree="$(cd "$root2" && GIT_INDEX_FILE="$root2/.git/fake-idx" git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,src/backend_scene && GIT_INDEX_FILE="$root2/.git/fake-idx" git write-tree)"
fake_commit="$(g -C "$root2" commit-tree "$fake_tree" -p HEAD -m fake)"
( cd "$root2" && gate_marker_matches "$fake_commit" ); rc=$?
check "an unresolvable submodule commit never matches" "$(yes_if "$rc" 1)"

# 11. Wiring: the lib is only useful if preflight.sh calls it and routes rc 79.
grep -q 'lib/gate_marker.sh' "$PREFLIGHT"; a=$?
grep -q 'gate_marker_should_write' "$PREFLIGHT"; b=$?
grep -q 'gate_marker_write' "$PREFLIGHT"; c=$?
check "preflight.sh sources the lib and writes the marker through should_write" "$(yes_if "$a$b$c" 000)"
sed -n '/Mutation gate (Mull --diff-only/,/^esac/p' "$PREFLIGHT" | grep -qE '^\s+79\)'; rc=$?
check "preflight.sh maps mutation rc 79 to a warning" "$(yes_if "$rc" 0)"
grep -E '^\s+79\)' "$PREFLIGHT" | grep -q 'fail '; rc=$?
check "the rc 79 branch never fails the gate, even under MUTATION_FATAL=1" "$(yes_if "$rc" 1)"
grep -q 'FUZZ_DEGRADED=1' "$PREFLIGHT"; rc=$?
check "preflight.sh flags a degraded fuzz run" "$(yes_if "$rc" 0)"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
