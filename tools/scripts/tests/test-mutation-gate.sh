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
# Records the per-mutant address-space limit this invocation observed, so a
# case can assert mutation.sh actually set ulimit -v before exec'ing the
# runner rather than trusting the wrapper silently worked.
if [[ -n "$dir" ]]; then
    mkdir -p "$dir"
    ulimit -Sv > "$dir/observed-ulimit.txt" 2>/dev/null || echo unlimited > "$dir/observed-ulimit.txt"
fi
# A per-target body wins over the shared one, so a case can give two targets
# different results for the same mutant -- which is the only way to see whether
# the aggregate treats "killed here, survived there" as killed.
tgt="$(basename "${dir:-}")"
var="STUB_REPORT_${tgt}"
body="${!var:-${STUB_REPORT:-none}}"
# STUB_REPORT=none reproduces a Mull run that died before reporting (the
# timed-out warmup); anything else is a JSON body to drop in as the report.
if [[ "$body" == "none" ]]; then
    echo "[error] Original test failed (warmup run)" >&2
    exit 1
fi
# A clean run with nothing in scope: Mull says so and writes no report at all.
# Distinct from "none", which is a run that died before it could report.
if [[ "$body" == "nomutants" ]]; then
    echo "[info] No mutants found. Mutation score: infinitely high"
    exit 0
fi
mkdir -p "$dir"
printf '%s' "$body" > "$dir/report.json"
STUB
    chmod +x "$path"
}

# A stub standing in for `ninja -t commands <target>` -- the post-build
# instrumentation check (mutation.sh's check_mull_instrumentation) invokes
# this, not the real build, so a case can pin exactly what the "compile
# commands" looked like without an actual cmake/ninja build.  Prints
# $STUB_NINJA_COMMANDS verbatim; the check only cares about the text of each
# line, never ninja's real dependency graph.
write_stub_ninja() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_NINJA_COMMANDS:-}"
STUB
    chmod +x "$path"
}

# Gives a make_root() sandbox what check_mull_instrumentation() needs to
# actually run against it, instead of taking its "no build.ninja -- nothing
# to check" early exit: a build.ninja placeholder (only its existence is
# read; its content never is) under the target's build dir, plus MULL_NINJA_BIN
# pointed at an absolute stub script so the check never touches PATH or a real
# ninja/distrobox.
prep_ninja_drift_root() {  # prep_ninja_drift_root <root> <build-dir-relative-to-root>
    local root="$1" build_dir="$2"
    mkdir -p "$root/$build_dir"
    : > "$root/$build_dir/build.ninja"
    write_stub_ninja "$root/stubbin/ninja"
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
    # Both configs, because every target now resolves one and the gate refuses
    # to mutate a target it cannot configure.
    cp "$REAL_ROOT/src/backend_scene/mull.yml" "$root/src/backend_scene/mull.yml"
    cp "$REAL_ROOT/tests/mull.yml" "$root/tests/mull.yml"
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


# Like report_json but every spec carries an explicit status, so a case can
# describe one target killing a mutant another target merely links.
report_json_status() {
    local root="$1"; shift
    python3 - "$root" "$@" <<'PYEOF'
import json, sys
root = sys.argv[1]
files = {}
for spec in sys.argv[2:]:
    rel, line, mutator, status = spec.rsplit(":", 3)
    key = f"{root}/{rel}"
    files.setdefault(key, {"mutants": []})["mutants"].append(
        {"id": f"{rel}:{line}", "mutatorName": mutator,
         "location": {"start": {"line": int(line)}}, "status": status})
print(json.dumps({"files": files}))
PYEOF
}

# Like report_json, but attaches a `source` field to the file entry (the whole
# file's text, as Mull's Elements reporter embeds it) and an explicit
# start/end line range per mutant, so the normalisation jq has something to
# slice the mutated line's text out of.  Args are
# "startline:endline:mutator" triples; all mutants land on the same file,
# since that is the only shape these tests need.
report_json_src() {  # report_json_src <root> <file> <source> <spec...>
    local root="$1" file="$2" source="$3"; shift 3
    python3 - "$root" "$file" "$source" "$@" <<'PY'
import json, sys
root, file, source = sys.argv[1], sys.argv[2], sys.argv[3]
specs = sys.argv[4:]
mutants = []
for spec in specs:
    startline, endline, mutator = spec.split(":")
    mutants.append({
        "id": f"{file}:{startline}", "mutatorName": mutator,
        "location": {"start": {"line": int(startline)}, "end": {"line": int(endline)}},
        "status": "Survived"})
files = {f"{root}/{file}": {"source": source, "mutants": mutants}}
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


# 6. Mull mutates the working tree, so the target selector has to read it too.
#    Reading only committed history runs the wrong binaries and reports
#    survivors that the missing binary would have killed -- a clean gate that
#    has measured nothing, which is the same failure this file exists for.
#    FileHelper.cpp is committed well before HEAD and edited only in the tree,
#    so committed history alone cannot see it.  origin/main exists here\n#    because that is what makes the three-dot range succeed in anger --\n#    without it the fallback diff, which does read the tree, hides the bug.
root="$(make_root)"
gitc() { git -C "$root" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$root/src"
printf 'int f(){return 0;}\n' > "$root/src/FileHelper.cpp"
gitc add src/FileHelper.cpp; gitc commit -q -m adds-filehelper
gitc update-ref refs/remotes/origin/main HEAD
printf 'x\n' > "$root/README.md"
gitc add README.md; gitc commit -q -m unrelated-tip
# The change under test: uncommitted, exactly like a sweep mid-review.
printf 'int f(){return 1;}\n' > "$root/src/FileHelper.cpp"
body="$(report_json "$root" "src/FileHelper.cpp:1:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --diff-only --strict)"; rc=$?
check "an uncommitted source change selects its own test binary" \
      "" "$rc" 1 "$out" "tst_filehelper"


# 7. A mutant is dead if any suite kills it.  Several binaries link the same
#    TU -- tst_playlist_manager compiles FileHelper.cpp for the one function it
#    needs -- so a mutant in a read path it never calls survives there while the
#    file's own suite kills it.  Unioning the per-target survivor lists reports
#    that as a finding; the honest aggregate subtracts what was killed.
root="$(make_root)"
gitc7() { git -C "$root" -c user.email=t@t -c user.name=t "$@"; }
printf '#!/bin/sh\nexit 0\n' > "$root/build/impl-mutation/tst_playlist_manager"
chmod +x "$root/build/impl-mutation/tst_playlist_manager"
mkdir -p "$root/src"
printf 'a\n' > "$root/src/FileHelper.cpp"; printf 'b\n' > "$root/src/PlaylistManager.cpp"
gitc7 add src/FileHelper.cpp src/PlaylistManager.cpp; gitc7 commit -q -m sources
gitc7 update-ref refs/remotes/origin/main HEAD
printf 'a2\n' > "$root/src/FileHelper.cpp"; printf 'b2\n' > "$root/src/PlaylistManager.cpp"
killed="$(report_json_status "$root" "src/FileHelper.cpp:144:cxx_gt_to_ge:Killed")"
lived="$(report_json_status "$root" "src/FileHelper.cpp:144:cxx_gt_to_ge:Survived")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 MULL_WORKERS=1 \
        STUB_REPORT="$lived" \
        STUB_REPORT_tst_filehelper="$killed" \
        STUB_REPORT_tst_playlist_manager="$lived" \
        "$GATE" --diff-only --strict 2>&1 )"; rc=$?
check "a mutant its own suite kills is not resurrected by another target" \
      "" "$rc" 0 "$out"


# 8. "Nothing to mutate" is a clean result, not a failed measurement.  Mull
#    writes no report when the diff holds no mutable lines -- a build-system or
#    comment-only change does this -- and the driver cannot tell that apart from
#    a run that died before reporting.  Reporting 78 there sends you hunting a
#    warmup timeout that never happened.
root="$(make_root)"
out="$(run_gate "$root" "nomutants" --target tst_filehelper --strict)"; rc=$?
check "a run with no mutants in scope is a pass, not an unmeasurable run" \
      "" "$rc" 0 "$out" "no mutants"

# 9. The baseline keys on line number alone, so an edit that inserts lines
#    above a survivor shifts it out from under its own entry: reported as a
#    brand-new survivor at the new line, while the stale entry never matches
#    anything again.  Matching on the mutated line's own text, not just its
#    number, survives the shift.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge","line_text":"if (x > 0) {"}]}
EOF
src=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\nif (x > 0) {'
body="$(report_json_src "$root" "src/FileHelper.cpp" "$src" "16:16:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
check "an inserted line above a survivor is matched by text, not reported new" \
      "" "$rc" 0 "$out" "line 16, was line 10"

# 10. The reverse of #9, and the test that stops the fix from collapsing to
#     "match on {file,mutator}, ignore the line entirely": the SAME file,
#     line and mutator, but a DIFFERENT expression, must still count as new.
#     Today's {file,line,mutator} key already matches here and reports a
#     false-negative "no new survivors" -- the shipped bug, not a crash.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge","line_text":"if (x > 0) {"}]}
EOF
src=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nif (y > 0) {'
body="$(report_json_src "$root" "src/FileHelper.cpp" "$src" "10:10:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
check "a different mutation at the same file, line and mutator is still reported new" \
      "" "$rc" 1 "$out" "new surviving mutant"

# 11. --refresh-baseline used to be an unconditional overwrite of the whole
#     file with this run's survivor set.  Scoping a refresh to one target
#     (or a --diff-only run) must never touch a baseline entry for a file
#     that target does not cover -- PlaylistManager.cpp here, which
#     tst_filehelper never links.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[
  {"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge"},
  {"file":"src/PlaylistManager.cpp","line":20,"mutator":"cxx_lt_to_le"}
]}
EOF
body="$(report_json "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 STUB_REPORT="$body" MULL_WORKERS=1 \
        "$GATE" --target tst_filehelper --refresh-baseline 2>&1 )"; rc=$?
after="$(cat "$root/tests/.mull-baseline.json")"
check "refreshing one target does not delete another target's baseline entries" \
      "" "$rc" 0 "$(printf '%s\n---baseline after---\n%s\n' "$out" "$after")" \
      '"file": "src/PlaylistManager.cpp"'

# 12. The other half of #11: a target's refresh must still drop its OWN
#     entries once they genuinely stop reproducing, or "scope-safe" would
#     have overcorrected into "refresh never removes anything".
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[
  {"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge"},
  {"file":"src/PlaylistManager.cpp","line":20,"mutator":"cxx_lt_to_le"}
]}
EOF
body="$(report_json_status "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge:Killed")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 STUB_REPORT="$body" MULL_WORKERS=1 \
        "$GATE" --target tst_filehelper --refresh-baseline 2>&1 )"; rc=$?
after="$(cat "$root/tests/.mull-baseline.json")"
combined="$(printf '%s\n---baseline after---\n%s\n' "$out" "$after")"
if [[ "$rc" == "0" ]] \
   && ! grep -q '"file": "src/FileHelper.cpp"' <<<"$after" \
   && grep -q '"file": "src/PlaylistManager.cpp"' <<<"$after"; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" \
        "refreshing after a genuine fix drops the now-dead entry, in scope"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" \
        "refreshing after a genuine fix drops the now-dead entry, in scope"
    sed 's/^/        | /' <<<"$combined" | tail -20
    FAIL=$((FAIL + 1))
fi

# 13. Outside of a refresh, a survivor the baseline still lists but the
#     current run no longer reproduces should be named as resolved -- not
#     silently ignored, and not treated as a reason to fail the gate.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge"}]}
EOF
body="$(report_json_status "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge:Killed")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
check "a survivor no longer reproduced is reported resolved without failing the gate" \
      "" "$rc" 0 "$out" "no longer survives"

# 14. clang-format reflows plenty of lines in this repo (`git log --oneline
#     --grep="^clang-format$" -i` turns up several standalone commits) --
#     reindentation or extra internal whitespace must not manufacture a new
#     survivor.  A comparison that only trims the outer edges would still
#     break on an internal reflow, so this pins collapsing internal runs too.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/FileHelper.cpp","line":10,"mutator":"cxx_gt_to_ge","line_text":"if (x > 0) {"}]}
EOF
src=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\n        if (x   >   0)   {  '
body="$(report_json_src "$root" "src/FileHelper.cpp" "$src" "14:14:cxx_gt_to_ge")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
check "reindentation of an unrelated wrapping change does not manufacture a new survivor" \
      "" "$rc" 0 "$out"

# 15. Required, not optional: reachable today.  ThumbnailGrabber.cpp has the
#     identical `else if (ev->event_id == MPV_EVENT_END_FILE) {` guard at two
#     separate lines, both live cxx_eq_to_ne candidates.  Matching on text
#     alone, with no tie-break, would fold both into one slot and silently
#     swallow the second mutant.  The baseline's one entry must claim only
#     its nearest twin; the other must still be reported new.
root="$(make_root)"
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/backend_mpv/ThumbnailGrabber.cpp","line":80,"mutator":"cxx_eq_to_ne","line_text":"else if (ev->event_id == MPV_EVENT_END_FILE) {"}]}
EOF
line='else if (ev->event_id == MPV_EVENT_END_FILE) {'
filler=""
for i in $(seq 1 79); do filler+="f$i"$'\n'; done
src="${filler}${line}"$'\n'
for i in $(seq 81 104); do src+="f$i"$'\n'; done
src+="${line}"
body="$(report_json_src "$root" "src/backend_mpv/ThumbnailGrabber.cpp" "$src" \
    "80:80:cxx_eq_to_ne" "105:105:cxx_eq_to_ne")"
out="$(run_gate "$root" "$body" --target tst_filehelper --strict)"; rc=$?
name="two identical-text mutants in the same file resolve by nearest line, not by first-match collision"
if [[ "$rc" == "1" ]] && grep -q ':105 \[cxx_eq_to_ne\]' <<<"$out" \
   && ! grep -q ':80 \[cxx_eq_to_ne\]' <<<"$out"; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
    sed 's/^/        | /' <<<"$out" | tail -20
    FAIL=$((FAIL + 1))
fi

# 16. A line can look like a perfectly normal statement and still be the
#     WRONG one: real baseline drift (found migrating the committed baseline
#     for this task) puts a comparison mutator's recorded line on a
#     statement with no comparison operator in it at all -- the code shifted
#     and dragged a different, unrelated statement into that line number.
#     "looks like a statement" alone waves that through; migrate must also
#     check the mutator's own operator is textually present.
root="$(make_root)"
mkdir -p "$root/src"
cat > "$root/src/Foo.cpp" <<'EOF'
int compute(int value) {
    const int cOpen = value;
    return cOpen;
}
EOF
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[{"file":"src/Foo.cpp","line":2,"mutator":"cxx_add_to_sub"}]}
EOF
out="$( cd "$root" && "$GATE" --migrate-baseline 2>&1 )"; rc=$?
after="$(cat "$root/tests/.mull-baseline.json")"
combined="$(printf '%s\n---baseline after---\n%s\n' "$out" "$after")"
if [[ "$rc" == "1" ]] && grep -qi "no '" <<<"$out" && ! grep -q '"line_text"' <<<"$after"; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" \
        "a line with no matching operator for its mutator is an orphan, not a migration"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" \
        "a line with no matching operator for its mutator is an orphan, not a migration"
    sed 's/^/        | /' <<<"$combined" | tail -20
    FAIL=$((FAIL + 1))
fi

# 17. An operator character INSIDE a quoted literal must not count as the
#     mutator's operator being present -- src/FileHelper.cpp:101 is exactly
#     this: `after == QLatin1Char('>')` has a `'>'` character literal but no
#     bare `>` comparison anywhere on the line, yet a plain substring test
#     sees the `>` byte and "migrates" cxx_gt_to_ge/cxx_gt_to_le onto it. Both
#     quoting styles have to be stripped before the check runs, and a sibling
#     line with a real, un-quoted operator must still migrate normally.
root="$(make_root)"
mkdir -p "$root/src"
cat > "$root/src/Foo.cpp" <<'EOF'
int check(int value, const char *sym) {
    bool q1 = (sym[0] == '>');
    bool q2 = (strcmp(sym, ">") == 0);
    if (value > 0) return 1;
    return 0;
}
EOF
cat > "$root/tests/.mull-baseline.json" <<'EOF'
{"survivors":[
  {"file":"src/Foo.cpp","line":2,"mutator":"cxx_gt_to_ge"},
  {"file":"src/Foo.cpp","line":3,"mutator":"cxx_gt_to_ge"},
  {"file":"src/Foo.cpp","line":4,"mutator":"cxx_gt_to_ge"}
]}
EOF
out="$( cd "$root" && "$GATE" --migrate-baseline 2>&1 )"; rc=$?
after="$(cat "$root/tests/.mull-baseline.json")"
combined="$(printf '%s\n---baseline after---\n%s\n' "$out" "$after")"
line2_text="$(jq -r '.survivors[] | select(.line==2) | .line_text // "MISSING"' <<<"$after")"
line3_text="$(jq -r '.survivors[] | select(.line==3) | .line_text // "MISSING"' <<<"$after")"
line4_text="$(jq -r '.survivors[] | select(.line==4) | .line_text // "MISSING"' <<<"$after")"
name="an operator inside a quoted literal (either quote style) is not mistaken for the operator itself"
if [[ "$rc" == "1" ]] && [[ "$line2_text" == "MISSING" ]] && [[ "$line3_text" == "MISSING" ]] \
   && [[ "$line4_text" == "if (value > 0) return 1;" ]]; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
    printf '        line2 line_text=%s line3 line_text=%s line4 line_text=%s\n' \
        "$line2_text" "$line3_text" "$line4_text"
    sed 's/^/        | /' <<<"$combined" | tail -20
    FAIL=$((FAIL + 1))
fi

# 18. A first-party TU behind a mutation-instrumented binary that carries no
#     -fpass-plugin (the exact shape a static library linked but never
#     instrumented left) must fail the run before any mutant is ever
#     measured -- not quietly report "no mutants in scope" for code Mull
#     never actually saw.  The ar/ranlib line ahead of the compile line is
#     load-bearing, not decoration: a real `ninja -t commands` dump is mostly
#     link/archive steps with no `-c <file>` in them at all, and a first draft
#     of this check read one via `x="$(grep ... | awk ...)"` -- under this
#     script's `set -o pipefail`, grep finding no match on that line exits 1,
#     the assignment inherits it, and `set -e` kills the whole gate right
#     there with no message at all.  A single-line stub never exercised that
#     line shape and shipped it anyway.
root="$(make_root)"
prep_ninja_drift_root "$root" "build/impl-mutation"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 WEK_IN_CI=1 MULL_WORKERS=1 \
        MULL_NINJA_BIN="$root/stubbin/ninja" STUB_REPORT=nomutants \
        STUB_NINJA_COMMANDS=$'/usr/bin/llvm-ar qc src/Utils/libwpUtils.a src/Utils/CMakeFiles/wpUtils.dir/Logging.cpp.o && /usr/bin/llvm-ranlib src/Utils/libwpUtils.a\nclang++ -Isomewhere -c /var/home/bazzite/build/wallpaper-engine-kde-plugin/src/backend_scene/src/Utils/FpsCounter.cpp -o CMakeFiles/wpUtils.dir/FpsCounter.cpp.o' \
        "$GATE" --target tst_filehelper --strict 2>&1 )"; rc=$?
check "a first-party TU built without -fpass-plugin fails before mutating" \
      "" "$rc" 1 "$out" "never instrumented"

# 19. The inverse of #18: the identical compile line (with the same leading
#     ar/ranlib line), this time correctly carrying -fpass-plugin, must not
#     trip the check -- proves #18 is testing the FLAG's presence, not merely
#     a first-party path showing up in the compile commands at all.
root="$(make_root)"
prep_ninja_drift_root "$root" "build/impl-mutation"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 WEK_IN_CI=1 MULL_WORKERS=1 \
        MULL_NINJA_BIN="$root/stubbin/ninja" STUB_REPORT=nomutants \
        STUB_NINJA_COMMANDS=$'/usr/bin/llvm-ar qc src/Utils/libwpUtils.a src/Utils/CMakeFiles/wpUtils.dir/Logging.cpp.o && /usr/bin/llvm-ranlib src/Utils/libwpUtils.a\nclang++ -Isomewhere -fpass-plugin=/plugin.so -c /var/home/bazzite/build/wallpaper-engine-kde-plugin/src/backend_scene/src/Utils/FpsCounter.cpp -o CMakeFiles/wpUtils.dir/FpsCounter.cpp.o' \
        "$GATE" --target tst_filehelper --strict 2>&1 )"; rc=$?
check "the same TU correctly instrumented does not trip the drift check" \
      "" "$rc" 0 "$out" "no mutants"

# 20. A diff range that ADDS a first-party file must get a second Mull pass
#     scoped to exactly that file (includePaths, no gitDiffRef), merged into
#     the same aggregate as the primary pass.  Mull's own git-diff filter has
#     no delta for a path absent from the base tree, so without this second
#     pass the added file's mutants are silently dropped no matter how much
#     arithmetic/comparison logic they hold.
root="$(make_root)"
gitc20() { git -C "$root" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$root/src"
printf 'int f(){return 0;}\n' > "$root/src/FileHelper.cpp"
gitc20 add src/FileHelper.cpp; gitc20 commit -q -m base
gitc20 update-ref refs/remotes/origin/main HEAD
# FileHelper.cpp is also edited here, not just NewHelper.cpp added: target
# selection maps changed files to binaries via tests/CMakeLists.txt, and
# NewHelper.cpp (not a real project source) maps to nothing on its own --
# without an edit to a file that DOES map to tst_filehelper, this diff would
# select no target at all and the added-files pass would never be reached.
printf 'int f(){return 1;}\n' > "$root/src/FileHelper.cpp"
printf 'bool eq(int a,int b){return a==b;}\n' > "$root/src/NewHelper.cpp"
gitc20 add src/FileHelper.cpp src/NewHelper.cpp
gitc20 commit -q -m edits-filehelper-adds-new-helper
primary_body="$(report_json "$root" "src/FileHelper.cpp:1:cxx_eq_to_ne")"
added_body="$(report_json "$root" "src/NewHelper.cpp:1:cxx_eq_to_ne")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 MULL_WORKERS=1 \
        STUB_REPORT_tst_filehelper="$primary_body" \
        STUB_REPORT_tst_filehelper_added="$added_body" \
        "$GATE" --diff-only --strict 2>&1 )"; rc=$?
added_cfg="$root/build/impl-mutation/mull-out/mull-tst_filehelper-added.yml"
name="an added first-party file gets its own includePaths pass with no gitDiffRef, merged into the aggregate"
if [[ "$rc" == "1" ]] \
   && grep -q 'src/FileHelper.cpp:1 \[cxx_eq_to_ne\]' <<<"$out" \
   && grep -q 'src/NewHelper.cpp:1 \[cxx_eq_to_ne\]' <<<"$out" \
   && [[ -f "$added_cfg" ]] \
   && grep -q 'includePaths' "$added_cfg" \
   && grep -q 'NewHelper' "$added_cfg" \
   && ! grep -q 'gitDiffRef' "$added_cfg"; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
    printf '        added_cfg=%s exists=%s\n' "$added_cfg" "$( [[ -f "$added_cfg" ]] && echo yes || echo no )"
    [[ -f "$added_cfg" ]] && sed 's/^/        cfg| /' "$added_cfg"
    sed 's/^/        | /' <<<"$out" | tail -25
    FAIL=$((FAIL + 1))
fi

# 21. The other half of #20: a diff range that only EDITS an existing file,
#     adding nothing new, must run Mull once -- the added-files pass is
#     additive on top of the existing diff-only behaviour, not an
#     unconditional second invocation every diff-only run now pays for.
root="$(make_root)"
gitc21() { git -C "$root" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$root/src"
printf 'int f(){return 0;}\n' > "$root/src/FileHelper.cpp"
gitc21 add src/FileHelper.cpp; gitc21 commit -q -m base
gitc21 update-ref refs/remotes/origin/main HEAD
printf 'int f(){return 1;}\n' > "$root/src/FileHelper.cpp"
gitc21 add src/FileHelper.cpp; gitc21 commit -q -m edits-filehelper
body="$(report_json "$root" "src/FileHelper.cpp:1:cxx_eq_to_ne")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 MULL_WORKERS=1 \
        STUB_REPORT_tst_filehelper="$body" \
        "$GATE" --diff-only --strict 2>&1 )"; rc=$?
added_dir="$root/build/impl-mutation/mull-out/tst_filehelper_added"
name="a diff with no added files runs Mull once -- no added-files pass is attempted"
if [[ "$rc" == "1" ]] && [[ ! -d "$added_dir" ]] && ! grep -qi 'added files' <<<"$out"; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
    printf '        added_dir=%s exists=%s\n' "$added_dir" "$( [[ -d "$added_dir" ]] && echo yes || echo no )"
    sed 's/^/        | /' <<<"$out" | tail -25
    FAIL=$((FAIL + 1))
fi

# 22. --no-renames: git's own similarity heuristic auto-detects renames (no
#     -M flag or diff.renames config needed -- confirmed on this box's git)
#     and reports the result as `R`, not `A`.  Under that default,
#     --diff-filter=A shows NOTHING for a renamed-and-edited file, which is
#     exactly the "new path Mull's own diff filter can't see" case the
#     added-files pass exists to catch.  --no-renames forces git to report it
#     as a plain add instead, regardless of what diff.renames is set to.
root="$(make_root)"
gitc22() { git -C "$root" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$root/src"
printf 'int f(){return 0;}\n' > "$root/src/FileHelper.cpp"
# Large body so a one-line tail edit still reads as a similarity-based rename
# (>50%) rather than a delete+add -- a short file wouldn't trigger it.
python3 -c "print('\n'.join(f'int line_{i}(){{return {i};}}' for i in range(60)))" \
    > "$root/src/BigHelper.cpp"
gitc22 add src/FileHelper.cpp src/BigHelper.cpp; gitc22 commit -q -m base
gitc22 update-ref refs/remotes/origin/main HEAD
gitc22 mv src/BigHelper.cpp src/RenamedHelper.cpp
sed -i '1s/.*/int line_0(){return 999;}/' "$root/src/RenamedHelper.cpp"
printf 'int f(){return 1;}\n' > "$root/src/FileHelper.cpp"
gitc22 add -A; gitc22 commit -q -m edits-filehelper-renames-bighelper
gitc22 diff --name-status origin/main -- . | grep -q '^R' \
    || { echo "  [setup] git did not detect the rename in this environment -- skipping"; }
primary_body="$(report_json "$root" "src/FileHelper.cpp:1:cxx_eq_to_ne")"
added_body="$(report_json "$root" "src/RenamedHelper.cpp:1:cxx_eq_to_ne")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 MULL_WORKERS=1 \
        STUB_REPORT_tst_filehelper="$primary_body" \
        STUB_REPORT_tst_filehelper_added="$added_body" \
        "$GATE" --diff-only --strict 2>&1 )"; rc=$?
added_cfg="$root/build/impl-mutation/mull-out/mull-tst_filehelper-added.yml"
name="a renamed-and-edited first-party file is still measured as added (--no-renames)"
if [[ "$rc" == "1" ]] \
   && [[ -f "$added_cfg" ]] \
   && grep -q 'RenamedHelper' "$added_cfg"; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
    printf '        added_cfg=%s exists=%s\n' "$added_cfg" "$( [[ -f "$added_cfg" ]] && echo yes || echo no )"
    [[ -f "$added_cfg" ]] && sed 's/^/        cfg| /' "$added_cfg"
    sed 's/^/        | /' <<<"$out" | tail -25
    FAIL=$((FAIL + 1))
fi

# 23. The added-files pass must be scoped to targets that actually compile the
#     added file, not run once per target that merely shares the diff with an
#     edited sibling source.  src/FileHelper.cpp (real tests/CMakeLists.txt
#     mapping) feeds THREE binaries: tst_filehelper, tst_playlist_manager,
#     tst_thumbnail_grabber.  src/backend_mpv/ThumbnailGrabber.cpp feeds only
#     two of those three (not tst_playlist_manager).  Editing the former and
#     adding the latter in the same diff must scope the added-files pass to
#     exactly the two that compile it -- before this fix, mull_added_files_
#     config_for() computed the added set once and handed the identical
#     includePaths to every selected target regardless of whether that target
#     ever compiled the file, so tst_playlist_manager got a wasted pass too.
root="$(make_root)"
printf '#!/bin/sh\nexit 0\n' > "$root/build/impl-mutation/tst_playlist_manager"
printf '#!/bin/sh\nexit 0\n' > "$root/build/impl-mutation/tst_thumbnail_grabber"
chmod +x "$root/build/impl-mutation/tst_playlist_manager" "$root/build/impl-mutation/tst_thumbnail_grabber"
gitc23() { git -C "$root" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$root/src/backend_mpv"
printf 'int f(){return 0;}\n' > "$root/src/FileHelper.cpp"
gitc23 add src/FileHelper.cpp; gitc23 commit -q -m base
gitc23 update-ref refs/remotes/origin/main HEAD
printf 'int f(){return 1;}\n' > "$root/src/FileHelper.cpp"
printf 'bool eq(int a,int b){return a==b;}\n' > "$root/src/backend_mpv/ThumbnailGrabber.cpp"
gitc23 add src/FileHelper.cpp src/backend_mpv/ThumbnailGrabber.cpp
gitc23 commit -q -m edits-filehelper-adds-thumbnailgrabber
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 MULL_WORKERS=1 STUB_REPORT=nomutants \
        "$GATE" --diff-only --strict 2>&1 )"; rc=$?
cfg_filehelper="$root/build/impl-mutation/mull-out/mull-tst_filehelper-added.yml"
cfg_thumbnail="$root/build/impl-mutation/mull-out/mull-tst_thumbnail_grabber-added.yml"
cfg_playlist="$root/build/impl-mutation/mull-out/mull-tst_playlist_manager-added.yml"
name="the added-files pass runs only for targets that compile the added file, not every target sharing the diff"
if [[ -f "$cfg_filehelper" ]] && [[ -f "$cfg_thumbnail" ]] && [[ ! -f "$cfg_playlist" ]]; then
    printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS + 1))
else
    printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
    printf '        cfg_filehelper exists=%s cfg_thumbnail exists=%s cfg_playlist exists=%s (want: yes yes no)\n' \
        "$( [[ -f "$cfg_filehelper" ]] && echo yes || echo no )" \
        "$( [[ -f "$cfg_thumbnail" ]] && echo yes || echo no )" \
        "$( [[ -f "$cfg_playlist" ]] && echo yes || echo no )"
    sed 's/^/        | /' <<<"$out" | tail -25
    FAIL=$((FAIL + 1))
fi

# 24. A compiled source path containing a space (ninja quotes such an
#     argument rather than leaving it bare) must still be recognised as a
#     first-party TU with no -fpass-plugin -- a parser that just splits the
#     line on whitespace after finding `-c` (the original one did, via `grep
#     -oE '-c [^ ]+\.cpp' | awk '{print $2}'`) truncates at the embedded
#     space and never matches the real, quoted path at all, so a TU like this
#     would silently pass the drift check uninstrumented.
root="$(make_root)"
prep_ninja_drift_root "$root" "build/impl-mutation"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 WEK_IN_CI=1 MULL_WORKERS=1 \
        MULL_NINJA_BIN="$root/stubbin/ninja" STUB_REPORT=nomutants \
        STUB_NINJA_COMMANDS=$'/usr/bin/llvm-ar qc src/Utils/libwpUtils.a src/Utils/CMakeFiles/wpUtils.dir/Logging.cpp.o && /usr/bin/llvm-ranlib src/Utils/libwpUtils.a\nclang++ -Isomewhere -c "/var/home/bazzite/build/wallpaper-engine-kde-plugin/src/backend_scene/src/Utils/Fps Counter.cpp" -o "CMakeFiles/wpUtils.dir/Fps Counter.cpp.o"' \
        "$GATE" --target tst_filehelper --strict 2>&1 )"; rc=$?
check "a compiled path containing a space is still recognised as uninstrumented" \
      "" "$rc" 1 "$out" "never instrumented"

# 25. A runaway mutant (a corrupted size or loop bound) must hit its OWN
#     memory cap instead of taking the whole sweep scope down with it -- the
#     failure mode mutation-sweep.sh exists to survive.  The cap is a
#     ulimit -v set on the runner's own process, inherited by every mutant it
#     forks, so an explicit MULL_MUTANT_AS_MB has to reach the runner exactly.
root="$(make_root)"
body="$(report_json "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 STUB_REPORT="$body" MULL_WORKERS=1 \
        MULL_MUTANT_AS_MB=2048 "$GATE" --target tst_filehelper --strict 2>&1 )"; rc=$?
observed="$(cat "$root/build/impl-mutation/mull-out/tst_filehelper/observed-ulimit.txt" 2>/dev/null)"
check "an explicit MULL_MUTANT_AS_MB reaches the runner as ulimit -v (KB)" \
      "" "$observed" "2097152" "$out"

# 26. Leaving the cap unset must not mean uncapped -- it falls back to the
#     documented default, measured against a clean instrumented
#     backend_scene_tests run (see mutation.sh).
root="$(make_root)"
body="$(report_json "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 STUB_REPORT="$body" MULL_WORKERS=1 \
        "$GATE" --target tst_filehelper --strict 2>&1 )"; rc=$?
observed="$(cat "$root/build/impl-mutation/mull-out/tst_filehelper/observed-ulimit.txt" 2>/dev/null)"
check "MULL_MUTANT_AS_MB unset applies the default cap, not no cap" \
      "" "$observed" "4194304" "$out"

# 27. A cap set below the measured healthy footprint would kill every clean
#     mutant, not just runaway ones -- the driver has to say so rather than
#     let that read as a wall of "survived" false negatives.
root="$(make_root)"
body="$(report_json "$root" "src/FileHelper.cpp:10:cxx_gt_to_ge")"
out="$( cd "$root" && MUTATION_SKIP_BUILD=1 STUB_REPORT="$body" MULL_WORKERS=1 \
        MULL_MUTANT_AS_MB=64 "$GATE" --target tst_filehelper --strict 2>&1 )"; rc=$?
check "a cap below the measured healthy footprint is flagged" \
      "" "$rc" 1 "$out" "below the measured healthy footprint"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
