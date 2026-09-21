#!/usr/bin/env bash
# Self-test for the fuzz corpus path wiring.
#
# run.sh used to read/write build/fuzz/corpus/<target>/{found,seed} while every
# other consumer -- minimize.sh, pin-regression.sh, preflight.sh's own fuzz-smoke
# gate -- agreed on build/sub/fuzz-corpus-<target> plus the committed
# tests/fuzz_corpus/<target>/seed. An overnight run.sh session wrote to a corpus
# tree nothing else ever read, and its seeded phase could never see the seed
# files already committed for most targets. Separately, the corpus size budget
# checked bytes only, never file count. This exercises both against a synthetic
# scratch tree and a stub fuzz binary -- no real fuzzing, no cmake, no
# distrobox, well under a second total.
#
#   tools/scripts/tests/test-fuzz-run.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUN_SH="$REAL_ROOT/tools/scripts/fuzz/run.sh"
BUDGET_LIB="$REAL_ROOT/tools/scripts/lib/fuzz_corpus_budget.sh"
PREFLIGHT="$REAL_ROOT/tools/scripts/preflight.sh"
PASS=0
FAIL=0
TMPS=()

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

cleanup() { for d in "${TMPS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

report() {  # report <name> <ok> <diagnostics>
    local name="$1" ok="$2" diag="$3"
    if [[ "$ok" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        [[ -n "$diag" ]] && sed 's/^/        | /' <<<"$diag" | tail -20
        FAIL=$((FAIL + 1))
    fi
}

echo "== fuzz run.sh / corpus budget self-test =="

# 1. run.sh both-mode passes the shared build/sub corpus and the committed
#    seed dir. A stub binary sits at both today's path (build/fuzz) and the
#    fixed path (build/sub) so the test observes which one run.sh actually
#    resolves, rather than failing early on "binary not found".
scratch="$(mktemp -d)"
TMPS+=("$scratch")
log="$scratch/invocations.log"
: > "$log"

write_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$log"
exit 0
STUB
    chmod +x "$path"
}
write_stub "$scratch/build/fuzz/src/Test/fuzz_FakeTarget"
write_stub "$scratch/build/sub/src/Test/fuzz_FakeTarget"

mkdir -p "$scratch/build/fuzz/corpus/FakeTarget/seed" \
         "$scratch/tests/fuzz_corpus/FakeTarget/seed"
printf 'x' > "$scratch/build/fuzz/corpus/FakeTarget/seed/x.bin"
printf 'x' > "$scratch/tests/fuzz_corpus/FakeTarget/seed/x.bin"

( cd "$scratch" && bash "$RUN_SH" FakeTarget 4 both ) >"$scratch/run.out" 2>&1

line_count=0
[[ -f "$log" ]] && line_count=$(wc -l < "$log")
both_lines_use_build_sub=1
if [[ -f "$log" ]]; then
    while IFS= read -r invocation; do
        [[ "$invocation" == *"build/sub/fuzz-corpus-FakeTarget"* ]] || both_lines_use_build_sub=0
    done < "$log"
else
    both_lines_use_build_sub=0
fi
seeded_line="$(grep 'tests/fuzz_corpus/FakeTarget/seed' "$log" 2>/dev/null || true)"
seeded_second_field=""
[[ -n "$seeded_line" ]] && seeded_second_field="$(awk '{print $2}' <<<"$seeded_line")"

ok1=1
[[ "$line_count" == "2" ]] || ok1=0
[[ "$both_lines_use_build_sub" == "1" ]] || ok1=0
[[ "$seeded_second_field" == "tests/fuzz_corpus/FakeTarget/seed" ]] || ok1=0

diag1="$(printf 'invocations.log (%s lines):\n%s\nrun.sh output:\n%s\n' \
    "$line_count" "$(cat "$log" 2>/dev/null)" "$(cat "$scratch/run.out")")"
report "run.sh both-mode passes the shared build/sub corpus and the committed seed dir" \
    "$ok1" "$diag1"

# 2. The corpus budget must reject too many small files, not just too many
#    bytes. The library doesn't exist before the fix, so sourcing it fails and
#    this case fails too -- the correct pre-fix red.
d_over="$(mktemp -d)"; TMPS+=("$d_over")
for i in $(seq 1 51); do printf 'x' > "$d_over/f$i"; done
out_over="$( (source "$BUDGET_LIB"; check_fuzz_corpus_budget "$d_over" 204800 50) 2>&1 )"
rc_over=$?

d_ok="$(mktemp -d)"; TMPS+=("$d_ok")
for i in 1 2 3; do printf 'x' > "$d_ok/f$i"; done
out_ok="$( (source "$BUDGET_LIB"; check_fuzz_corpus_budget "$d_ok" 204800 50) 2>&1 )"
rc_ok=$?

ok2=1
[[ "$rc_over" != "0" ]] || ok2=0
grep -qiF 'file' <<<"$out_over" || ok2=0
[[ "$rc_ok" == "0" ]] || ok2=0

diag2="$(printf '51-file case: rc=%s out=%s\n3-file case: rc=%s out=%s\n' \
    "$rc_over" "$out_over" "$rc_ok" "$out_ok")"
report "fuzz corpus budget rejects too many small files" "$ok2" "$diag2"

# 3. preflight.sh must actually call the shared budget helper, not just
#    mention its name in a comment, and the old bytes-only inline loop must
#    be gone.
call_lines="$(grep -n 'check_fuzz_corpus_budget "' "$PREFLIGHT" || true)"
real_call="$(grep -vE '^[0-9]+:[[:space:]]*#' <<<"$call_lines" || true)"
old_loop_count="$(grep -c 'du -bs "\$d"' "$PREFLIGHT" || true)"
old_loop_count="${old_loop_count:-0}"

ok3=1
[[ -n "$real_call" ]] || ok3=0
[[ "$old_loop_count" == "0" ]] || ok3=0

diag3="$(printf 'call sites found:\n%s\nold inline-loop occurrences: %s\n' \
    "${call_lines:-<none>}" "$old_loop_count")"
report "preflight wires the shared budget check into its fuzz-corpus loop, not just a comment mention" \
    "$ok3" "$diag3"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
