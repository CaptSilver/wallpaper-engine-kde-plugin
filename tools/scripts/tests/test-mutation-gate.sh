#!/usr/bin/env bash
# Self-test for the mutation gate's decision logic.
#
# Testing a test runner sounds circular, but this gate is the thing that decides
# whether a push is allowed, and it spent about three months reporting a verdict
# it had never computed: Mull's warmup exceeded the timeout, Mull treats that as
# fatal and emits no report, and the driver turned the resulting nonzero exit
# into "new surviving mutant(s)".  A broken measurement is indistinguishable from
# a finding unless something asserts the difference -- that is what this file is.
#
# It never invokes Mull.  A stub runner stands in for it, so the whole suite runs
# in seconds against a synthetic repo root, and each case pins one decision the
# gate has to get right.
#
#   tools/scripts/tests/test-mutation-gate.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="$REAL_ROOT/tools/scripts/mutation.sh"
PASS=0
FAIL=0
TMPS=()

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

cleanup() { for d in "${TMPS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

# A stub standing in for mull-runner.  Answers the capability probe, then either
# writes an Elements report into --report-dir or writes nothing at all,
# according to $STUB_REPORT in its environment.
write_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
# --help is the driver's capability probe; naming Elements selects that reporter.
for a in "$@"; do
    if [[ "$a" == "--help" ]]; then
        echo "  - Elements:  Mutation Testing Elements JSON/HTML report"
        exit 0
    fi
done
dir=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--report-dir" ]] && dir="$a"
    prev="$a"
done
# STUB_REPORT=none reproduces a Mull run that died before reporting (the
# timed-out warmup); anything else is a JSON body to drop in as the report.
if [[ "${STUB_REPORT:-none}" == "none" ]]; then
    echo "[error] Original test failed (warmup run)" >&2
    exit 1
fi
mkdir -p "$dir"
printf '%s' "$STUB_REPORT" > "$dir/report.json"
STUB
    chmod +x "$path"
}

# Build a synthetic repo root the gate can run against.
make_root() {
    local root
    root="$(mktemp -d /tmp/wek-mutgate-XXXXXX)"
    TMPS+=("$root")
    # A real git repo, because the gate resolves its own working tree with
    # `git rev-parse` and overwrites any inherited _SUPER.  Making the sandbox a
    # repo is the honest seam: the gate runs exactly the code it runs in anger.
    git -C "$root" init -q
    mkdir -p "$root/build/impl-mutation" \
             "$root/build/impl-mutation-sub/src/Test" \
             "$root/tests" \
             "$root/src/backend_scene"
    write_stub "$root/build/impl-mutation/_mull/usr/bin/mull-runner-22"
    # Stand-in test binaries: the gate only checks they are executable.
    printf '#!/bin/sh\nexit 0\n' > "$root/build/impl-mutation/tst_filehelper"
    printf '#!/bin/sh\nexit 0\n' > "$root/build/impl-mutation-sub/src/Test/backend_scene_tests"
    chmod +x "$root/build/impl-mutation/tst_filehelper" \
             "$root/build/impl-mutation-sub/src/Test/backend_scene_tests"
    cp "$REAL_ROOT/src/backend_scene/mull.yml" "$root/src/backend_scene/mull.yml"
    printf '{"survivors":[]}\n' > "$root/tests/.mull-baseline.json"
    printf '%s' "$root"
}

# An Elements report body.  Args are "relpath:line:mutator" triples, made
# absolute under $root so the driver's repo-leaf stripping has something to bite.
report_json() {
    local root="$1"; shift
    python3 - "$root" "$@" <<'PY'
import json, sys
root = sys.argv[1]
files = {}
for spec in sys.argv[2:]:
    rel, line, mutator = spec.rsplit(":", 2)
    key = f"{root}/{rel}"
    files.setdefault(key, {"mutants": []})["mutants"].append(
        {"id": f"{rel}:{line}", "mutatorName": mutator,
         "location": {"start": {"line": int(line)}}, "status": "Survived"})
print(json.dumps({"files": files}))
PY
}

run_gate() {  # run_gate <root> <stub-report> <args...> ; echoes output, returns rc
    local root="$1" body="$2"; shift 2
    ( cd "$root" && MUTATION_SKIP_BUILD=1 STUB_REPORT="$body" \
        MULL_WORKERS=1 "$GATE" "$@" 2>&1 )
}

check() {  # check <name> <condition-desc> <actual-rc> <expected-rc> <output> [must-contain]
    local name="$1" rc="$3" want="$4" out="$5" needle="${6:-}"
    local ok=1
    [[ "$rc" == "$want" ]] || ok=0
    [[ -n "$needle" ]] && ! grep -qiF -- "$needle" <<<"$out" && ok=0
    if [[ "$ok" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        printf '        expected rc=%s got rc=%s' "$want" "$rc"
        [[ -n "$needle" ]] && printf ', expected output to contain: %s' "$needle"
        printf '\n'
        sed 's/^/        | /' <<<"$out" | tail -15
        FAIL=$((FAIL + 1))
    fi
}

echo "== mutation gate self-test =="

# 1. The regression that started this: a runner that dies before reporting must
#    not be laundered into a survivor verdict.
root="$(make_root)"
out="$(run_gate "$root" none --target tst_filehelper --strict)"; rc=$?
check "a run that produces no report exits 78, not a survivor verdict" \
      "" "$rc" 78 "$out" "no target produced a mutation report"

# 2. The root cause: Mull silently not reading mull.yml.  The only observable
#    symptom was survivors from paths the config excludes, so assert on that
#    rather than on the config having been passed.
root="$(make_root)"
body="$(report_json "$root" "src/backend_scene/third_party/nlohmann/json.hpp:12:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --target backend_scene_tests --strict)"; rc=$?
check "survivors from an excluded path fail the run" \
      "" "$rc" 1 "$out" "excluded"

# 3. Same defect, caught one step earlier: no config means an unfiltered run,
#    which is twice the work and mutates third_party.  Refuse rather than drift.
root="$(make_root)"
rm -f "$root/src/backend_scene/mull.yml"
body="$(report_json "$root" "src/WPShaderParser.cpp:10:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --target backend_scene_tests --strict)"; rc=$?
check "a missing mull.yml fails instead of mutating unfiltered" \
      "" "$rc" 1 "$out" "mull.yml"

# 4. The verdict has to survive being printed.  With more survivors than the
#    listing shows, head closes the pipe; under `set -euo pipefail` that used to
#    kill the script with 141 before it reached its own pass/fail decision.
root="$(make_root)"
specs=(); for i in $(seq 1 40); do specs+=("src/FileHelper.cpp:$i:cxx_gt_to_ge"); done
body="$(report_json "$root" "${specs[@]}")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
check "40 new survivors exit 1 with a verdict, not SIGPIPE" \
      "" "$rc" 1 "$out" "new surviving mutant"

# 5. The happy path still passes: everything already in the baseline is not new.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge"}]}
EOF
body="$(report_json "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
check "survivors already in the baseline pass" \
      "" "$rc" 0 "$out" "no new surviving mutants"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
