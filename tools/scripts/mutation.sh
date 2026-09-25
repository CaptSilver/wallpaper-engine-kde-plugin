#!/usr/bin/env bash
# tools/scripts/mutation.sh — Mull-driven mutation testing for parent + submodule C++ tests.
#
# Usage:
#   tools/scripts/mutation.sh                          # full run, diff vs baseline
#   tools/scripts/mutation.sh --diff-only              # run only on changed-file binaries
#   tools/scripts/mutation.sh --refresh-baseline       # rebuild + merge into tests/.mull-baseline.json
#   tools/scripts/mutation.sh --target tst_filehelper  # one binary
#   tools/scripts/mutation.sh --migrate-baseline       # backfill line_text on every existing entry
#   tools/scripts/mutation.sh --list-targets           # print the instrumented binary names
#   tools/scripts/mutation.sh --list-sources           # print the 'source<TAB>binary' map
#   tools/scripts/mutation.sh --strict                 # treat new survivors as fatal (rc=1, default)
#   tools/scripts/mutation.sh --no-strict              # informational mode (rc=0 even with new survivors)
#   tools/scripts/mutation.sh --help                   # this help
#
# Baseline diff:
#   Survivors are matched to the baseline on {file, mutator, line_text} --
#   the mutated line's own trimmed, whitespace-collapsed text -- not on line
#   number, with a nearest-line tie-break when two mutants share identical
#   text in the same file (real in this codebase: ThumbnailGrabber.cpp has
#   the same `else if (... MPV_EVENT_END_FILE)` guard twice).  A line number
#   alone orphans a baseline entry the moment an edit inserts code above it.
#   New (no baseline match) -> fail (rc=1) unless --no-strict.
#   Moved (baseline match, but the line shifted) -> informational note.
#   Killed (baseline entry no longer reproduced, for a file this run
#     actually mutated) -> informational note (does not fail).
#   --refresh-baseline merges this run's measured survivors into the files
#   it actually covered, leaving every other file's baseline entries
#   untouched -- a full run (no --target/--diff-only) covers every file, so
#   this degrades to a plain overwrite in that case.  --migrate-baseline
#   rewrites every existing entry in place, reading the mutated line back out
#   of the current working tree, instead of running Mull at all.
#
# Builds (two trees, parallel):
#   - Parent:    build/impl-mutation/      with -DMUTATION_TESTING=ON over tests/
#   - Submodule: build/impl-mutation-sub/  with -DBUILD_TESTS=ON -DMUTATION_TESTING=ON
#                over src/backend_scene/.  Only backend_scene_tests is mutation-
#                instrumented (wek_apply_mull_instrumentation() in
#                src/backend_scene/cmake/WekMullInstrument.cmake, called on the
#                test executable AND every first-party library it links);
#                scenescript_tests is excluded.
#
# Diff mode and added files:
#   Mull's own gitDiffRef filter finds no delta for a path absent from the
#   base tree, so a file added since the diff base is invisible to it no
#   matter how much mutable logic it holds.  --diff-only compensates with a
#   second pass per target: whatever first-party files `git diff
#   --diff-filter=A` reports since the same base, mutated in full via
#   includePaths (no gitDiffRef), reported into a second directory that
#   aggregates alongside the primary pass.  Skipped when nothing was added.
#
# MOC ignore:
#   Mutants in Qt-generated moc_*.cpp / *.moc / *_autogen/ files are dropped
#   from the survivor set during normalisation — Qt autogen churn would
#   otherwise generate constant false positives (the pre-MOC-ignore baseline
#   was 18 entries, all Qt MOC).
#
# Runner: discovered dynamically — host-PATH mull-runner-NN preferred, then the
# binary fetched into build/impl-mutation*/_mull/usr/bin/.
#
# Wired into the default preflight gate via `tools/scripts/mutation.sh --diff-only --strict`
# (minutes, scaling with how many mutable lines the branch touched; 0 min when no
# mapped sources changed).  A full run is hours, not minutes: backend_scene_tests
# alone holds ~3700 mutants once third_party and the test sources are excluded,
# and every one of them re-runs the whole ~31s suite.  Budget for that before
# invoking this without --diff-only, and see mull_config_for() for why the
# diff scoping is load-bearing rather than a nicety.
#
# Exit codes: 0=clean / 1=new survivors (a --migrate-baseline orphan, or a
#             first-party TU built without Mull's instrumentation) / 2=arg error /
#             77=runner or build unavailable / 78=no target produced a report.
set -euo pipefail

# Shared RAM-aware parallelism helper (resolved before the cd below, since it is
# addressed relative to this script, not the working tree).
_MUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MUT_DIR/lib/mem.sh"

# Resolve to the parent repo's working tree even when invoked from inside the
# `src/backend_scene` submodule (mirrors tools/scripts/preflight.sh).
_SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
cd "${_SUPER:-$(git rev-parse --show-toplevel)}"

BUILD="build/impl-mutation"
BUILD_SUB="build/impl-mutation-sub"
OUT_DIR="$BUILD/mull-out"
BASELINE="tests/.mull-baseline.json"

# Per-target build dir resolver — parent binaries live in $BUILD, the single
# submodule mutation-instrumented binary lives under $BUILD_SUB/src/Test/.
bin_path() {
    local t="$1"
    case "$t" in
        backend_scene_tests) echo "$BUILD_SUB/src/Test/$t" ;;
        *) echo "$BUILD/$t" ;;
    esac
}

# The ninja build-dir ROOT for a target (what `ninja -C <root>` wants), as
# opposed to bin_path()'s full executable path.  Same split as bin_path().
mull_build_root_for() {
    local t="$1"
    case "$t" in
        backend_scene_tests) echo "$BUILD_SUB" ;;
        *) echo "$BUILD" ;;
    esac
}

MODE="full"          # full | diff | migrate -- purely target/binary selection
                     # (migrate short-circuits before any of that runs at all)
TARGET=""
STRICT=1
REFRESH=0            # set only by --refresh-baseline.  Kept independent of
                     # MODE so a --target or --diff-only run can refresh too --
                     # the merge is scope-safe (see the refresh section below),
                     # so refreshing from a partial run no longer means
                     # silently deleting every baseline entry it didn't cover.
# Chunked-sweep support.  A full sweep of backend_scene_tests is ~3700 mutants
# that each re-run the whole suite -- many hours, on a desktop that will not
# stay quiet that long.  These let a caller slice it into independently
# restartable pieces whose reports accumulate side by side in $OUT_DIR, so an
# interruption costs one chunk instead of the whole run.  See mutation-sweep.sh.
INCLUDE_PATHS=""     # comma-separated regexes -> Mull includePaths
OUT_SUFFIX=""        # per-run report subdir suffix, keeps chunks from colliding
WIPE_OUT=1           # 0 keeps earlier chunks' reports in place
AGGREGATE_ONLY=0     # skip build+mutate, just aggregate what is already there
LIST_TARGETS=0       # print the target list and exit; keeps callers from
                     # duplicating it and drifting out of step with ALL_TARGETS
LIST_SOURCES=0       # print the src-file -> target map and exit (same reason)
while (( $# )); do
    case "$1" in
        --diff-only)        MODE="diff"; shift ;;
        --include-paths)    INCLUDE_PATHS="$2"; shift 2 ;;
        --out-suffix)       OUT_SUFFIX="$2"; shift 2 ;;
        --no-wipe)          WIPE_OUT=0; shift ;;
        --aggregate-only)   AGGREGATE_ONLY=1; shift ;;
        --list-targets)     LIST_TARGETS=1; shift ;;
        --list-sources)     LIST_SOURCES=1; shift ;;
        --refresh-baseline) REFRESH=1; shift ;;
        --migrate-baseline) MODE="migrate"; shift ;;
        --target)           TARGET="$2"; shift 2 ;;
        --strict)           STRICT=1; shift ;;
        --no-strict)        STRICT=0; shift ;;
        --help|-h)
            # The header comment (line 2 through the last consecutive `#` line
            # before `set -euo pipefail`) printed by its shape, not a hard-coded
            # line range -- a fixed range rots the moment the header grows and
            # silently truncates mid-sentence.
            awk 'NR==1 {next} !/^#/ {exit} {print}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Aggregating an existing set of chunk reports means doing none of the work that
# produced them: no build, no wipe, no runner.
if [[ "$AGGREGATE_ONLY" == "1" ]]; then
    WIPE_OUT=0
    MUTATION_SKIP_BUILD=1
fi

# ── Output helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; BLUE=$'\033[1;34m'
    YELLOW=$'\033[1;33m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; BLUE=""; YELLOW=""; RESET=""
fi
step() { printf '\n%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  warn%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf '\n%sFAIL:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ── --migrate-baseline: backfill line_text, no Mull involved ─────────────────
# Reads every existing entry's file+line straight out of the current working
# tree and records the trimmed, whitespace-collapsed text found there, so the
# baseline diff below has something to match on besides a line number.  Pure
# file reads against the tree Mull would otherwise mutate -- no build, no
# runner, no distrobox.
#
# Known limitation: a pre-migration entry only ever recorded one line, not the
# start/end span a real Mull report carries, so a mutant whose statement wraps
# across lines (clang-format's 100-column wrap does this fairly often) gets a
# truncated line_text here -- only the first physical line, not the whole
# statement.  The next time Mull actually re-measures that exact mutant, its
# line_text_of() reads the true span and won't match the truncated one,
# reporting a one-time "new"/"killed" pair for a mutant that did not change.
# That is a real, bounded gap: fixing it needs the true span, which only a
# fresh Mull run provides, so it is left as a known cost of bootstrapping
# line_text onto an already-drifted baseline rather than guessed at here.
#
# An entry whose recorded line no longer holds anything that looks like a
# statement is a line that has already drifted -- exactly the case this
# whole change exists to stop silently mismeasuring -- so it is reported as
# an orphan rather than guessed at.  That is a per-entry decision, not an
# all-or-nothing one: refusing to write anything just because one entry out
# of a few hundred has drifted would make this unusable on any baseline that
# is not freshly refreshed, which defeats the point of a permanent
# subcommand meant to be re-run over time.  Entries that do resolve are
# migrated and written; orphans are named and left exactly as they were
# (still present, matching on {file,mutator} with a null line_text, same as
# before this ran), and the run exits nonzero to say the baseline is not yet
# fully migrated -- loud, not silent, without discarding the progress made.
if [[ "$MODE" == "migrate" ]]; then
    step "Migrating $BASELINE: recording each entry's mutated-line text"
    command -v jq >/dev/null || fail "jq not found on host — required to rewrite $BASELINE"
    command -v python3 >/dev/null || fail "python3 not found on host — required for --migrate-baseline's quoted-literal check"
    [[ -s "$BASELINE" ]] || fail "no baseline to migrate: $BASELINE"
    # Second check, beyond "is this a statement at all": does the line even
    # contain the operator this specific mutator flips?  A drifted line can
    # look like a perfectly ordinary statement and still be the WRONG one --
    # real baseline drift did exactly this (found migrating the committed
    # baseline: a cxx_add_to_sub entry landed on a line with no `+` or `-` at
    # all, because the code had shifted and dragged an unrelated declaration
    # into that line number).  Covers every mutator this project's mull.yml
    # actually produces; a mutator not listed here is left unchecked rather
    # than guessed at.
    declare -A _mutator_op=(
        [cxx_lt_to_ge]='<' [cxx_lt_to_le]='<'
        [cxx_gt_to_ge]='>' [cxx_gt_to_le]='>'
        [cxx_ge_to_gt]='>=' [cxx_ge_to_lt]='>='
        [cxx_le_to_lt]='<=' [cxx_le_to_gt]='<='
        [cxx_eq_to_ne]='==' [cxx_ne_to_eq]='!='
        [cxx_add_to_sub]='+' [cxx_sub_to_add]='-'
        [cxx_mul_to_div]='*' [cxx_div_to_mul]='/'
        [cxx_rem_to_div]='%'
        [cxx_pre_inc_to_pre_dec]='++' [cxx_post_inc_to_post_dec]='++'
    )
    # An operator character sitting inside a quoted string or char literal is
    # not the operator Mull could mutate -- src/FileHelper.cpp:101 has exactly
    # this shape, `after == QLatin1Char('>')`: the only `>` on the line is the
    # character literal `'>'`, not a comparison, but a plain substring test
    # can't tell the difference and "migrates" cxx_gt_to_ge/cxx_gt_to_le onto
    # it. Blank out every quoted span (both quote styles, backslash-escapes
    # respected) before testing for the operator's presence.
    _strip_quoted_literals() {
        WEK_STRIP_INPUT="$1" python3 -c '
import os, re
s = os.environ["WEK_STRIP_INPUT"]
s = re.sub(r"\x27(?:[^\x27\\]|\\.)*\x27", "", s)
s = re.sub(r"\x22(?:[^\x22\\]|\\.)*\x22", "", s)
print(s)
'
    }
    ORPHANS=()
    MIGRATE_TSV="$(mktemp)"
    trap 'rm -f "$MIGRATE_TSV"' EXIT
    while IFS=$'\t' read -r idx file line mutator; do
        [[ -z "$idx" ]] && continue
        if [[ ! -f "$file" ]]; then
            ORPHANS+=("$file:$line ($mutator) — file not found in working tree")
            continue
        fi
        raw="$(sed -n "${line}p" "$file" 2>/dev/null || true)"
        trimmed="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
        # A blank line, a line that is nothing but braces/parens/semicolons,
        # or a comment opener are never what Mull mutated -- the recorded
        # line has moved and this entry is an orphan, not a mutable statement.
        # (Regex kept in a variable, not inlined: an unquoted `(` or `;`
        # inside [[ =~ ]] is parsed as shell syntax before it is a pattern.)
        _orphan_re='^[(){};]*$'
        if [[ -z "$trimmed" ]] || [[ "$trimmed" =~ $_orphan_re ]] \
           || [[ "${trimmed:0:2}" == "//" ]] || [[ "${trimmed:0:2}" == "/*" ]]; then
            ORPHANS+=("$file:$line ($mutator) — no plausible mutable statement (got: '$trimmed')")
            continue
        fi
        _req_op="${_mutator_op[$mutator]:-}"
        if [[ -n "$_req_op" ]]; then
            _unquoted="$(_strip_quoted_literals "$trimmed")"
            if [[ "$_unquoted" != *"$_req_op"* ]]; then
                ORPHANS+=("$file:$line ($mutator) — text has no '$_req_op' outside quoted literals for this mutator (got: '$trimmed')")
                continue
            fi
        fi
        printf '%s\t%s\n' "$idx" "$trimmed" >> "$MIGRATE_TSV"
    done < <(jq -r '.survivors | to_entries[] | [.key, .value.file, .value.line, .value.mutator] | @tsv' "$BASELINE")

    if [[ ${#ORPHANS[@]} -gt 0 ]]; then
        warn "orphaned baseline entries (recorded line no longer holds mutable code) — left unmigrated:"
        printf '  %s\n' "${ORPHANS[@]}" >&2
    fi

    # Only entries $m actually resolved get a line_text key at all -- an
    # orphan is left with no key rather than an explicit null, so it stays
    # visibly unmigrated instead of looking like a deliberate "no text" call.
    jq --rawfile _map "$MIGRATE_TSV" '
      ( $_map | rtrimstr("\n") | split("\n") | map(select(length > 0) | split("\t"))
        | map({(.[0]): .[1]}) | add // {}
      ) as $m
      | .survivors |= (
          to_entries
          | map(($m[(.key | tostring)]) as $t | if $t != null then (.value + {line_text: $t}) else .value end)
        )
    ' "$BASELINE" > "$BASELINE.tmp" && mv "$BASELINE.tmp" "$BASELINE"
    MIGRATED_N=$(jq '[.survivors[] | select(has("line_text"))] | length' "$BASELINE")
    TOTAL_N=$(jq '.survivors | length' "$BASELINE")
    if [[ ${#ORPHANS[@]} -gt 0 ]]; then
        fail "migrated $MIGRATED_N/$TOTAL_N entries; ${#ORPHANS[@]} orphaned (see above) — fix or drop them by hand, then re-run --migrate-baseline"
    fi
    ok "migrated $MIGRATED_N/$TOTAL_N baseline entries with line_text"
    exit 0
fi

# ── Distrobox routing (mirrors preflight.sh) ─────────────────────────────────
inside_fedora() {
    [[ "${WEK_IN_CI:-}" == "1" || "${CI:-}" == "true" || "${CI:-}" == "1" ]] && return 0
    [[ -f /run/.containerenv ]] && grep -q 'name="fedora"' /run/.containerenv 2>/dev/null
}
if inside_fedora || ! command -v distrobox >/dev/null 2>&1; then
    DBOX_PREFIX=()
else
    DBOX_PREFIX=(distrobox enter fedora --)
fi
dbox() { "${DBOX_PREFIX[@]}" bash -lc "$*"; }

# ── Determine target/source lists (BEFORE builds so we skip unneeded ones) ───
# tests/CMakeLists.txt already states which tst_* targets carry -fpass-plugin
# and which src/*.cpp each of them compiles, so mutation_targets.py reads it
# rather than this script keeping its own copy.  A hand copy here is worse
# than stale documentation: a source that maps to no target reads as "nothing
# to check" instead of "we don't know", so --diff-only reports green over code
# it never mutated.  Landing a new instrumented target means adding its
# add_executable()/-fpass-plugin block there and nowhere else.
#
# Resolved relative to this script, not the working tree: the --diff-only
# self-test in tests/scripts/test_mutation.sh deliberately runs this script
# against a throwaway synthetic git repo to exercise the diff-mapping logic in
# isolation, and that repo has no tests/CMakeLists.txt of its own -- the
# target/source lists must always come from the real one.
MUTATION_TARGETS_PY="$_MUT_DIR/lib/mutation_targets.py"
MUTATION_CMAKELISTS="$_MUT_DIR/../../tests/CMakeLists.txt"
if ! command -v python3 >/dev/null; then
    fail "python3 not found on host — required to read mutation.sh's target list out of tests/CMakeLists.txt"
fi
if ! ALL_TARGETS_TXT="$(python3 "$MUTATION_TARGETS_PY" "$MUTATION_CMAKELISTS" --targets)"; then
    fail "mutation_targets.py failed to parse $MUTATION_CMAKELISTS"
fi
mapfile -t ALL_TARGETS <<< "$ALL_TARGETS_TXT"
ALL_TARGETS+=(backend_scene_tests)  # submodule target; not in tests/CMakeLists.txt at all

# Captured into a variable, not piped in through a process substitution: a
# crash in there leaves SRC_TO_TARGETS empty without tripping `set -e`, and an
# empty map is exactly what --diff-only reads as "nothing to check".
if ! SRC_MAP_TXT="$(python3 "$MUTATION_TARGETS_PY" "$MUTATION_CMAKELISTS" --sources)"; then
    fail "mutation_targets.py failed to map sources from $MUTATION_CMAKELISTS"
fi
declare -A SRC_TO_TARGETS=()
while IFS=$'\t' read -r _mt_src _mt_tgt; do
    [[ -z "$_mt_src" ]] && continue
    if [[ -n "${SRC_TO_TARGETS[$_mt_src]:-}" ]]; then
        SRC_TO_TARGETS[$_mt_src]+=" $_mt_tgt"
    else
        SRC_TO_TARGETS[$_mt_src]="$_mt_tgt"
    fi
done <<< "$SRC_MAP_TXT"

if [[ "$LIST_TARGETS" == "1" ]]; then
    printf '%s\n' "${ALL_TARGETS[@]}"
    exit 0
fi
if [[ "$LIST_SOURCES" == "1" ]]; then
    for _mt_src in "${!SRC_TO_TARGETS[@]}"; do
        for _mt_tgt in ${SRC_TO_TARGETS[$_mt_src]}; do
            printf '%s\t%s\n' "$_mt_src" "$_mt_tgt"
        done
    done | sort
    exit 0
fi

TARGETS=()
if [[ -n "$TARGET" ]]; then
    TARGETS=("$TARGET")
elif [[ "$MODE" == "diff" ]]; then
    # Map changed source paths -> instrumented test target name via
    # SRC_TO_TARGETS (derived above from tests/CMakeLists.txt).  Any change
    # anywhere under src/backend_scene/
    # (including the gitlink in the parent diff) triggers backend_scene_tests;
    # mutation is heavy enough that finer-grained submodule mapping isn't worth
    # the maintenance cost.
    # Committed range UNION the working tree.  Mull mutates the tree as it
    # stands, so a selector reading only committed history picks the wrong
    # binaries: a source edited but not yet committed gets mutated while the
    # suite that covers it never runs, and every one of its mutants is then
    # reported as surviving.  That reads as a finding and is really a gate that
    # measured nothing.  Note the HEAD~1 fallback already diffs against the
    # tree (no range), so only the three-dot path needed widening -- which is
    # why this stayed invisible in any checkout without an origin/main.
    CHANGED="$(
        {
            git diff --name-only origin/main...HEAD 2>/dev/null \
                || git diff --name-only HEAD~1 2>/dev/null || true
            git diff --name-only HEAD 2>/dev/null || true
        } | sort -u
    )"
    declare -A SEEN=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Parent file → every instrumented target that compiles it (a source
        # can feed more than one binary, e.g. FileHelper.cpp is linked into
        # tst_filehelper, tst_thumbnail_grabber and tst_playlist_manager).
        for t in ${SRC_TO_TARGETS[$f]:-}; do
            SEEN[$t]=1
        done
        # Submodule change (gitlink at src/backend_scene OR any path under it)
        # → backend_scene_tests.  Catches the parent's gitlink-bump commit
        # form, where individual submodule sources don't appear here.
        if [[ "$f" == "src/backend_scene" || "$f" == src/backend_scene/* ]]; then
            SEEN[backend_scene_tests]=1
        fi
    done <<< "$CHANGED"
    TARGETS=("${!SEEN[@]}")
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        ok "no changed sources mapped to mutation targets — exit 0"
        exit 0
    fi
else
    TARGETS=("${ALL_TARGETS[@]}")
fi
step "targets: ${TARGETS[*]}"

# ── Build only what's needed ─────────────────────────────────────────────────
# Bound the instrumented build's own parallelism by available RAM: a -g clang
# compile of the instrumented TUs is memory-heavy, and inside preflight this
# gate races the other legs' builds.  MULL_BUILD_MB is the per-job RSS budget.
MULL_BUILD_JOBS="${MULL_BUILD_JOBS:-$(mem_bounded_jobs "${MULL_BUILD_MB:-1536}")}"
NEED_PARENT=0
NEED_SUB=0
for t in "${TARGETS[@]}"; do
    case "$t" in
        backend_scene_tests) NEED_SUB=1 ;;
        *) NEED_PARENT=1 ;;
    esac
done

# Testability seam, and useful when you know the instrumented binaries are
# current: skip straight to mutating what is already built.  The gate's self-test
# (tools/scripts/tests/test-mutation-gate.sh) relies on it to run against a
# synthetic tree in seconds instead of configuring cmake.
if [[ "${MUTATION_SKIP_BUILD:-0}" == "1" ]]; then
    warn "MUTATION_SKIP_BUILD=1 — mutating the binaries already in $BUILD / $BUILD_SUB"
    NEED_PARENT=0
    NEED_SUB=0
fi

if [[ "$NEED_PARENT" == "1" ]]; then
    step "Configure + build parent tests with -DMUTATION_TESTING=ON"
    # Fresh build dir keeps coverage / mutation flag combinations from clashing.
    if [[ ! -f "$BUILD/CMakeCache.txt" ]]; then
        dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
              cmake -B $BUILD -S tests -G Ninja \
                    -DMUTATION_TESTING=ON -DCMAKE_BUILD_TYPE=Debug" \
            || fail "mutation configure failed (parent)"
    fi
    dbox "cmake --build $BUILD -j$MULL_BUILD_JOBS" || fail "mutation build failed (parent)"
    ok "parent mutation build complete"
fi

if [[ "$NEED_SUB" == "1" ]]; then
    step "Configure + build submodule (backend_scene_tests only) with -DMUTATION_TESTING=ON"
    if [[ ! -f "$BUILD_SUB/CMakeCache.txt" ]]; then
        dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
              cmake -B $BUILD_SUB -S src/backend_scene -G Ninja \
                    -DBUILD_TESTS=ON -DMUTATION_TESTING=ON -DCMAKE_BUILD_TYPE=Debug" \
            || fail "mutation configure failed (submodule)"
    fi
    dbox "cmake --build $BUILD_SUB --target backend_scene_tests -j$MULL_BUILD_JOBS" \
        || fail "mutation build failed (submodule)"
    ok "submodule mutation build complete"
fi

# ── Discover the mull-runner ─────────────────────────────────────────────────
# Pin version suffix lives in FetchMull.cmake only; this driver follows whatever
# the fetched build dir exposed.  Either parent or submodule build dir may have
# fetched the runner — check both.
RUNNER=""
for candidate in \
    "$BUILD/_mull/usr/bin/mull-runner-21" \
    "$BUILD/_mull/usr/bin/mull-runner-22" \
    "$BUILD/_mull/usr/bin/mull-runner" \
    "$BUILD_SUB/_mull/usr/bin/mull-runner-21" \
    "$BUILD_SUB/_mull/usr/bin/mull-runner-22" \
    "$BUILD_SUB/_mull/usr/bin/mull-runner" \
; do
    if [[ -x "$candidate" ]]; then RUNNER="$candidate"; break; fi
done
if [[ -z "$RUNNER" ]]; then
    # Fall back to PATH / wildcard scan of _deps and _mull (both build trees).
    if RUNNER=$(command -v mull-runner-21 || command -v mull-runner-22 \
                || command -v mull-runner 2>/dev/null) \
       && [[ -x "$RUNNER" ]]; then
        :
    else
        RUNNER=$(find "$BUILD" "$BUILD_SUB" -path '*/_mull/*' -name 'mull-runner*' -executable 2>/dev/null \
                  | head -1 || true)
    fi
fi
if [[ -z "$RUNNER" || ! -x "$RUNNER" ]] && [[ "$AGGREGATE_ONLY" != "1" ]]; then
    warn "mull-runner unavailable — rebuild with -DMUTATION_TESTING=ON or install Mull"
    exit 77
fi
ok "runner: $RUNNER"

# jq parses Mull's Elements/IDE report into the shared survivor schema below.
# Checked here rather than up top on purpose: the fast-skip (unmapped diff →
# exit 0) and the no-runner exit above never touch jq, so they must not require
# it — the Fedora CI unit-test image ships without jq.
if ! command -v jq >/dev/null; then
    fail "jq not found on host — install with 'sudo dnf install jq' (or your distro equivalent)"
fi

# ── Run Mull, collect Elements JSON, normalise to a shared survivor schema ───
# Mull 0.31+ supports `--reporters Elements` which emits Mutation Testing Elements
# JSON (`.files[<path>].mutants[]` with `id` / `mutatorName` / `location.start.line`
# / `status`).  Per-target reports land under $OUT_DIR/<target>/ and aggregate
# into all-survivors.json keyed by file+line+mutator.
[[ "$WIPE_OUT" == "1" ]] && rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
PROBE_OUT=""
[[ "$AGGREGATE_ONLY" != "1" ]] && PROBE_OUT="$("$RUNNER" --help 2>&1 || true)"
USE_ELEMENTS=1
if [[ "$AGGREGATE_ONLY" != "1" ]] && ! grep -qE '\bElements\b' <<<"$PROBE_OUT"; then
    USE_ELEMENTS=0
    warn "Mull --reporters=Elements unavailable; falling back to IDE-reporter parsing"
fi

ANY_BIN=0
# Distinct from ANY_BIN: a binary can exist, run, and still yield no report
# (Mull treats a timed-out warmup as fatal).  Without this the aggregate globs
# nothing, jq errors, and the run reports a survivor diff computed from no data
# -- which reads as a regression instead of a broken measurement.
ANY_REPORT=0
# MOC ignore regex (jq test()) — Qt's autogen tree is constant churn and not
# first-party code; mutants in moc_*.cpp / *.moc / *_autogen/ paths are noise.
MOC_IGNORE='_autogen/|/moc_|\.moc$'

# Shared jq function library, prepended (string-concatenated, not passed as a
# separate program) to every jq filter below that needs it.  One definition of
# "same mutant" for: extracting a mutant's own source text out of an Elements
# report, matching survivors across a run against the baseline, and merging
# survivor/killed lists that came from different targets or different chunks
# of a sweep.
#
#   line_text_of(fileval; startline; endline) -- slice fileval.source (the
#     whole file's text, as Elements embeds it) between the mutant's start
#     and end line, trim, and collapse internal whitespace runs to one space.
#     Collapsing (not just trimming) matters here: this repo lands standalone
#     clang-format commits, and a plain trim still breaks on an internal
#     reflow.  Returns null when fileval carries no source (the IDE-reporter
#     fallback path) -- both sides of a comparison come back null then, and
#     null equals null, so that path degrades to matching on {file,mutator}.
#
#   key_of(x) -- {file, mutator, line_text} as an array, used as the identity
#     for "same mutant" everywhere below.  A line number is deliberately not
#     part of it: inserting code above a survivor shifts its line without
#     changing what it is, and re-keying on the raw line orphans the entry.
#
#   greedy_pairs(bs; cs) / match_all(base; cur) -- within one key, two
#     mutants can share identical text at different lines (ThumbnailGrabber.cpp
#     has the same `else if (... MPV_EVENT_END_FILE)` guard twice); pairing by
#     nearest line distance, closest first, resolves that instead of the first
#     candidate silently swallowing every later one.  match_all returns
#     {pairs, leftover_b, leftover_c}: pairs are matched mutants (same
#     identity, possibly a different line), leftover_c is "in cur but nothing
#     in base matches" (new), leftover_b is "in base but nothing in cur
#     matches" (killed, once restricted to files this run actually mutated).
#
#   fold_merge(arrs) -- folds a list of survivor/killed arrays (one per
#     target, or one per chunk of a --no-wipe sweep) into one canonical array,
#     collapsing matched entries into one.  Needed because a chunked sweep can
#     span a code edit between chunks: without it, one physical mutant
#     reported at two different lines by two chunks counts as two.
#
#   subtract_dead(cur; killed) -- survivors in cur with no matching identity
#     in killed.  A mutant killed by one target's suite must not resurface as
#     surviving because another target links the same translation unit
#     without exercising that line.
JQ_LIB='
def line_text_of(fileval; startline; endline):
  (fileval.source) as $src
  | if ($src == null) then null
    else
      ($src | split("\n")) as $lines
      | ((startline // 0) | if . < 1 then 1 else . end) as $s
      | ((endline // $s) | if . < $s then $s else . end) as $e
      | ($lines[($s - 1):$e] | join(" "))
      | gsub("^\\s+|\\s+$"; "")
      | gsub("\\s+"; " ")
    end;

def key_of(x): [x.file, x.mutator, (x.line_text // null)];

def greedy_pairs(bs; cs):
  if (bs | length) == 0 or (cs | length) == 0 then
    {pairs: [], leftover_b: bs, leftover_c: cs}
  else
    ( [ range(0; bs | length) as $bi
        | range(0; cs | length) as $ci
        | {bi: $bi, ci: $ci,
           d: ((bs[$bi].line // 0) - (cs[$ci].line // 0) | if . < 0 then -. else . end)}
      ] | sort_by(.d) | .[0]
    ) as $best
    | (bs | to_entries | map(select(.key != $best.bi) | .value)) as $bs2
    | (cs | to_entries | map(select(.key != $best.ci) | .value)) as $cs2
    | greedy_pairs($bs2; $cs2) as $rest
    | { pairs: ([{b: bs[$best.bi], c: cs[$best.ci]}] + $rest.pairs),
        leftover_b: $rest.leftover_b,
        leftover_c: $rest.leftover_c }
  end;

# base/cur are captured into $base/$cur immediately: jq function arguments are
# filters, re-evaluated wherever the parameter name appears, not values frozen
# at the call site.  The reduce below rebinds `.` to its own accumulator, so a
# caller passing the bare `.` as base/cur (fold_merge does) would otherwise see
# base/cur silently start meaning "the reduce accumulator" partway through.
def match_all(base; cur):
  (base) as $base
  | (cur) as $cur
  | ($base + $cur | map(key_of(.)) | unique) as $keys
  | reduce $keys[] as $k (
      {pairs: [], leftover_b: [], leftover_c: []};
      . as $acc
      | ($base | map(select(key_of(.) == $k))) as $bs
      | ($cur  | map(select(key_of(.) == $k))) as $cs
      | greedy_pairs($bs; $cs) as $r
      | { pairs: ($acc.pairs + $r.pairs),
          leftover_b: ($acc.leftover_b + $r.leftover_b),
          leftover_c: ($acc.leftover_c + $r.leftover_c) }
    );

def fold_merge(arrs):
  reduce arrs[] as $nxt ([];
    . as $acc
    | match_all($acc; $nxt) as $r
    | $r.leftover_b + ($r.pairs | map(.b)) + $r.leftover_c
  );

def subtract_dead(cur; killed):
  match_all(killed; cur).leftover_c;
'
# Parallelism + timeout: Mull defaults to serial, which makes a single Qt test
# binary run ~15-20 min (a single tst_filehelper had ~155 mutants × ~7s each).
# Default to all cores (nproc); the per-process HOME isolation in
# tests/TestSandbox.h is what makes parallel-safe.
#
# Timeouts are a two-knob system:
#   --timeout: hard ceiling per test run (warmup + every mutant); applies even
#     when Mull's baseline*10 logic would compute a lower number.  This has to
#     fit a whole *instrumented* run of the slowest target, because Mull's
#     warmup run is subject to it too -- and a warmup that times out is fatal
#     to Mull, so the run produces no report at all rather than a partial one.
#     backend_scene_tests is the binding constraint: ~31s uninstrumented and
#     appreciably slower under Mull, and it grows with every added doctest.
#     Keep real headroom here; the cost of a generous ceiling is only paid by a
#     mutant that genuinely hangs.
#   --minimum-timeout: floor for the computed per-mutant timeout
#     (Mull picks max(baseline*10, minimum-timeout)).  Keeps fast parent tests
#     from getting too aggressive a deadline (a 100ms tst_plugininfo would
#     otherwise time out at 1s).
#
# MULL_WORKERS / MULL_TIMEOUT_MS / MULL_MIN_TIMEOUT_MS env overrides for
# low-core machines or CI box throttling.
# Worker count is bounded by available RAM, not just cores: Mull forks --workers
# parallel runs of an *instrumented* binary, so peak RSS is workers × per-binary
# RSS.  32 concurrent instrumented backend_scene_tests is what OOM'd 30 GB boxes.
# MULL_WORKER_MB is the per-worker RSS budget; an explicit MULL_WORKERS wins.
# 768 MB is measured, not guessed: `/usr/bin/time -v` on the instrumented
# backend_scene_tests peaks at 411 MB (the 64 MiB-JSON cap tests dominate it).
MULL_WORKERS="${MULL_WORKERS:-$(mem_bounded_jobs "${MULL_WORKER_MB:-768}")}"
[[ "$MULL_WORKERS" -lt 1 ]] && MULL_WORKERS=1

# Free RAM is the wrong boundary here, so cap concurrency separately.
# mem_bounded_jobs bounds on host MemAvailable, but on a systemd desktop the
# thing that actually stops this run is systemd-oomd watching *memory pressure*
# per slice: it kills the whole slice at >80% pressure for 20s, and it does that
# long before free memory runs out.  Mutation testing is unusually good at
# provoking it -- re-exec'ing a ~150 MB instrumented binary once per mutant,
# thousands of times, N at a time, is sustained reclaim activity by
# construction.  Measured on a 30 GB workstation: 10 workers drove the slice
# from 1.9 GB to 17.1 GB and got the session killed, twice, with free RAM still
# showing 20 GB available.  Raise it only if you can watch
# /proc/pressure/memory stay low for the whole run.
MULL_MAX_WORKERS="${MULL_MAX_WORKERS:-6}"
if (( MULL_WORKERS > MULL_MAX_WORKERS )); then
    MULL_WORKERS="$MULL_MAX_WORKERS"
fi
MULL_TIMEOUT_MS="${MULL_TIMEOUT_MS:-300000}"
MULL_MIN_TIMEOUT_MS="${MULL_MIN_TIMEOUT_MS:-5000}"
ok "mull parallelism: $MULL_WORKERS workers (RAM-bounded, cap nproc), build -j$MULL_BUILD_JOBS, ${MULL_TIMEOUT_MS}ms ceiling / ${MULL_MIN_TIMEOUT_MS}ms floor"

# Per-mutant address-space cap. Nothing bounds a single mutant today: a
# corrupted size or loop bound allocates without limit, and that took a whole
# sweep down twice (systemd-oomd killing every worker in the scope, not just
# the offending mutant -- see mutation-sweep.sh). run_mull_pass() sets this as
# `ulimit -v` in a subshell around each "$RUNNER" call below; rlimits survive
# fork+exec, so mull-runner and every mutant process it forks inherit the same
# cap. A mutant that exceeds it fails its own allocation and dies -- Mull
# records that as killed, which is the right verdict for it.
#
# ulimit -v bounds virtual address space, not RSS, because RSS undercounts
# what this binary actually reserves: Vulkan/Qt map large ranges the tests
# never touch. Measured on a clean full run of the instrumented
# backend_scene_tests (two runs, `systemd-run --user --scope -p
# MemoryHigh=6G -p MemoryMax=8G`, polling /proc/<pid>/status): VmPeak 2.30 GiB,
# VmHWM ~470 MB. 4096 MB leaves ~1.7x headroom over that before a clean
# mutant would ever hit the cap.
MULL_MUTANT_AS_MB="${MULL_MUTANT_AS_MB:-4096}"
MULL_HEALTHY_VSZ_MB=2355
if (( MULL_MUTANT_AS_MB < MULL_HEALTHY_VSZ_MB )); then
    warn "MULL_MUTANT_AS_MB=$MULL_MUTANT_AS_MB is below the measured healthy footprint (~${MULL_HEALTHY_VSZ_MB} MB) — clean mutants may be killed by the cap, not just runaway ones"
fi
ok "mull per-mutant cap: ${MULL_MUTANT_AS_MB}MB virtual address space (ulimit -v)"

# Resolved via PATH by default (inside the box, same as clang/cmake); the
# instrumentation-drift self-test overrides this to an absolute stub path so
# it can pin canned `-t commands` output without a real ninja build or an
# actual distrobox entry.
MULL_NINJA_BIN="${MULL_NINJA_BIN:-ninja}"
# Mull looks for its config as ./mull.yml, or wherever $MULL_CONFIG points.  We
# run the runner from the superproject root and build from build/impl-mutation-sub,
# and neither holds one -- so src/backend_scene/mull.yml has never been read, and
# every run logged "Mull cannot find config (mull.yml). Using some defaults."
# Its excludePaths matter a lot: unfiltered, backend_scene_tests carries 7324
# mutants, 22% of them inside third_party (doctest.h, nlohmann) and 28% in the
# test sources themselves.  Reading the config drops that to 3688.
#
# In diff mode we also hand Mull its own incremental filter, which is what makes
# --diff-only mean "mutants on lines this branch touched" instead of merely
# "targets this branch touched".  Without it, any submodule change ran all 7324
# mutants, each costing a full run of the ~31s suite -- about seven hours.
#
# Both configs are excludePaths-only where it matters, so wiring them changes
# which paths get mutated, not which mutators run.  Parent binaries need this as
# much as the submodule one: they link submodule sources, so unconfigured they
# mutate kissfft and vog/sha1.
# _MULL_CFG_PATH / _MULL_CFG_ROOT / _MULL_CFG_REF: mull_config_for()'s result
# is read from these globals, NOT from stdout -- a caller that captured it via
# $(mull_config_for "$t") would run the whole function in a subshell, and
# every one of these assignments would vanish the instant that subshell exits.
# _MULL_CFG_ROOT/_MULL_CFG_REF exist so the added-files pass below
# (mull_added_files_config_for(), below) can reuse the exact project root and
# diff base this function just resolved -- an added file is meaningless
# without knowing which ref it was added SINCE, and re-deriving that
# separately would drift the moment one of the two picked a different
# fallback (e.g. origin/main missing locally). All three are reset on every
# call, including the early-return paths, so a target that doesn't reach the
# diff branch (a full sweep, or one with no mull.yml) never leaves a previous
# target's config/ref lying around for the next one to misread.
# Which committed mull.yml a target's config derives from, and the project
# root to run git/Mull operations against for it -- the
# backend_scene_tests-vs-everything-else branch mull_config_for() and
# mull_added_files_config_for() both need, factored out here so the two can't
# quietly diverge on which target maps to which paths.  Writes into
# _MULL_SRC_YML/_MULL_SRC_ROOT rather than returning via stdout, for the same
# subshell reason _MULL_CFG_PATH exists below.
_MULL_SRC_YML=""
_MULL_SRC_ROOT=""
mull_src_root_for() {
    local t="$1"
    if [[ "$t" == "backend_scene_tests" ]]; then
        _MULL_SRC_YML="$PWD/src/backend_scene/mull.yml"
        _MULL_SRC_ROOT="$PWD/src/backend_scene"
    else
        # Parent binaries link submodule sources, so they need the exclusions
        # just as much: without a config they mutate kissfft and vog/sha1, which
        # is where ~98 of the committed baseline's entries came from.
        _MULL_SRC_YML="$PWD/tests/mull.yml"
        _MULL_SRC_ROOT="$PWD"
    fi
}

_MULL_CFG_PATH=""
_MULL_CFG_ROOT=""
_MULL_CFG_REF=""
mull_config_for() {
    local t="$1" src root ref cfg
    _MULL_CFG_PATH=""
    _MULL_CFG_REF=""
    mull_src_root_for "$t"
    src="$_MULL_SRC_YML"
    root="$_MULL_SRC_ROOT"
    _MULL_CFG_ROOT="$root"
    [[ -f "$src" ]] || return 0
    # A chunked sweep needs its own derived config even outside diff mode, so
    # build one whenever includePaths are in play.
    if [[ "$MODE" != "diff" && -z "$INCLUDE_PATHS" ]]; then _MULL_CFG_PATH="$src"; return 0; fi
    # Diff base, resolved inside the submodule -- it has its own history, so the
    # parent's range says nothing about which submodule lines changed.
    ref=""
    [[ "$MODE" == "diff" ]] && ref="$(git -C "$root" rev-parse --verify --quiet origin/main 2>/dev/null || true)"
    if [[ "$MODE" == "diff" ]]; then
        [[ -z "$ref" ]] && ref="$(git -C "$root" rev-parse --verify --quiet HEAD~1 2>/dev/null || true)"
        [[ -z "$ref" ]] && { _MULL_CFG_PATH="$src"; return 0; }
    fi
    _MULL_CFG_REF="$ref"
    cfg="$OUT_DIR/mull-$t${OUT_SUFFIX:+-$OUT_SUFFIX}.yml"
    {
        cat "$src"
        if [[ -n "$INCLUDE_PATHS" ]]; then
            # includePaths narrows the sweep to one chunk's files.  Mull ANDs it
            # with excludePaths, so the vendored/test exclusions still hold.
            printf '\nincludePaths:\n'
            local IFS=,
            for re in $INCLUDE_PATHS; do printf '  - %s\n' "$re"; done
        fi
        [[ "$MODE" == "diff" ]] && printf 'gitProjectRoot: %s\ngitDiffRef: %s\n' "$root" "$ref"
    } > "$cfg"
    _MULL_CFG_PATH="$cfg"
}

# Escape a literal string for use inside an anchored (^...$) extended regex --
# every ERE metacharacter neutralised so an absolute path with dots in it
# (every path here has at least one, in the extension) matches itself and
# nothing else.
_mull_regex_escape() {
    printf '%s' "$1" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g'
}

# Whether target t plausibly compiles first-party file f.  For a parent test
# binary this reuses SRC_TO_TARGETS -- the same tests/CMakeLists.txt-derived
# map the diff-only target-selection loop above already trusts for "which
# targets does this changed file touch", companion-header inference and all
# (FileHelper.hpp counts wherever FileHelper.cpp does).  Submodule paths
# aren't in that map at all (mutation_targets.py only reads the parent's
# tests/CMakeLists.txt), so backend_scene_tests keeps the same coarse "every
# submodule path counts" policy the target-selection loop already applies to
# it, rather than reading zero targets here and silently dropping the file.
#
# A file with NO entry in SRC_TO_TARGETS at all -- a genuinely new file that
# isn't wired into any add_executable() yet, or a header the sibling-header
# heuristic doesn't pair up -- counts for every target rather than none: the
# map only ever narrows a KNOWN, already-mapped file to the targets that
# actually compile it, it never becomes grounds to drop an unknown file from
# every target's measurement (that would just resurrect the added-files
# pass's original blind spot from the other direction).
_mull_target_compiles() {
    local t="$1" f="$2"
    [[ "$t" == "backend_scene_tests" ]] && return 0
    [[ -z "${SRC_TO_TARGETS[$f]:-}" ]] && return 0
    local mapped
    for mapped in ${SRC_TO_TARGETS[$f]:-}; do
        [[ "$mapped" == "$t" ]] && return 0
    done
    return 1
}

# A file added since the diff base is invisible to Mull's own git filter:
# gitDiffRef reads `git diff base_tree -> workdir`, which is blind to a path
# absent from base_tree entirely -- a file added since the ref has no delta
# and so no line ranges, and every mutant inside it is silently dropped from
# a --diff-only run no matter how much arithmetic or comparison logic it
# holds.  WPSceneHidePattern.hpp (added in ceda056) is the case that surfaced
# this: `A` in `git diff --name-status origin/main`, mutants embedded in the
# compiled object, none ever admitted.
#
# Requires mull_config_for() to have already run for this target THIS run --
# reuses its resolved root/ref via _MULL_CFG_ROOT/_MULL_CFG_REF rather than
# re-deriving them, so the two functions can never disagree about which ref
# "added" means relative to.
mull_added_files_config_for() {
    local t="$1" src root ref cfg added
    root="$_MULL_CFG_ROOT"
    ref="$_MULL_CFG_REF"
    [[ -z "$root" || -z "$ref" ]] && { printf ''; return; }
    mull_src_root_for "$t"
    src="$_MULL_SRC_YML"
    [[ -f "$src" ]] || { printf ''; return; }
    # First-party sources only: skip third_party (excludePaths drops it anyway,
    # so a second pass over it would only cost a wasted runner invocation) and
    # src/Test (doctest bodies + fuzz harnesses under src/Test/fuzz/ -- neither
    # is product code, and mull.yml excludes the whole directory already).
    # --no-renames: without it, --diff-filter=A depends on the machine's
    # diff.renames config -- with rename detection on, a moved-and-edited
    # first-party file shows up as `R`, not `A`, and this loop would never see
    # it even though it is exactly the "new path Mull's git filter can't see"
    # case this function exists to catch.
    added="$(git -C "$root" diff --no-renames --name-only --diff-filter=A "$ref" -- . 2>/dev/null \
        | grep -E '\.(cpp|cc|cxx|h|hpp)$' \
        | grep -vE '(^|/)third_party/|(^|/)src/Test/' || true)"
    [[ -z "$added" ]] && { printf ''; return; }
    # Scope to files this target actually compiles.  Without this, an added
    # file rides along in every target's includePaths merely because it
    # shares the diff with an edited file that also maps to that target --
    # e.g. FileHelper.cpp feeds three test binaries, so a diff that edits it
    # and separately adds one new source used to run the (expensive) added-
    # files pass three times, twice against binaries that never compiled the
    # new file at all.
    added="$(
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            _mull_target_compiles "$t" "$f" && printf '%s\n' "$f"
        done <<< "$added"
    )"
    [[ -z "$added" ]] && { printf ''; return; }
    cfg="$OUT_DIR/mull-$t${OUT_SUFFIX:+-$OUT_SUFFIX}-added.yml"
    {
        cat "$src"
        # Anchored, escaped absolute paths -- not the `.*/name.*` wildcard style
        # excludePaths uses -- because we want EXACTLY these newly-added files,
        # and nothing else: an unanchored pattern would also match any other
        # file in the tree whose path happens to contain the same substring.
        printf '\nincludePaths:\n'
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            printf '  - ^%s$\n' "$(_mull_regex_escape "$root/$f")"
        done <<< "$added"
        # Deliberately no gitProjectRoot/gitDiffRef here: includePaths already
        # narrows the sweep to exactly the added files, and the whole point is
        # to measure them in full rather than through a diff filter that (per
        # the defect this exists to close) cannot see them at all.
    } > "$cfg"
    printf '%s' "$cfg"
}

# A target's own -fpass-plugin block never reaches the static libraries it
# links -- target_compile_options only ever touches the target it's called
# on, so a first-party library could carry zero embedded mutants
# while the binary linking it looked completely ordinary.  Catch a
# recurrence the way this one was originally found: ask ninja for the
# target's own compile commands (resolved transitively through every static
# library it links) and look for a first-party TU with no -fpass-plugin.
MULL_TU_EXCLUDE_RE='(^|/)third_party/|(^|/)src/Test/'

# Pulls the argument to -c out of one ninja compile-command line, robust to a
# path containing a space: ninja quotes such an argument (double or single
# quotes) rather than leaving it bare, so the original parser -- split on
# whitespace after a plain `grep -oE '-c [^ ]+\.ext'` -- truncated at the
# first embedded space and matched an incomplete, wrong path.  Tries both
# quoted forms before falling back to the bare unquoted one.  Always exits 0
# (even on no match): a caller doing `var=$(_mull_extract_c_arg ...)` is a
# simple command under this script's `set -e`, and the parser it replaces
# crashed the whole script silently the moment it hit a line with no match
# (see the `|| true` comment at the call site's history) -- a bash function
# returning nonzero from a failed [[ =~ ]] test would trip the exact same trap.
_mull_extract_c_arg() {
    local line="$1"
    if [[ "$line" =~ -c\ \"([^\"]+\.(cpp|cc|cxx|mm))\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ -c\ \'([^\']+\.(cpp|cc|cxx|mm))\' ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ -c\ ([^\ ]+\.(cpp|cc|cxx|mm)) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
    return 0
}

check_mull_instrumentation() {
    local t="$1" bin="$2" root ninja_target cmds line src_file
    local -a missing=()
    root="$(mull_build_root_for "$t")"
    # No build.ninja to ask -- either a non-Ninja generator, or (the hermetic
    # self-test's synthetic root) no real build at all.  Nothing to check.
    [[ -f "$root/build.ninja" ]] || return 0
    ninja_target="${bin#"$root"/}"
    if ! cmds="$(dbox "'$MULL_NINJA_BIN' -C '$root' -t commands '$ninja_target'" 2>/dev/null)"; then
        warn "ninja -t commands failed for $t — skipping instrumentation-drift check"
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Most lines in a ninja command dump are link/ar/ranlib steps with no
        # `-c <file>` at all -- _mull_extract_c_arg prints nothing for those
        # and this just moves on to the next line.
        src_file="$(_mull_extract_c_arg "$line")"
        [[ -z "$src_file" ]] && continue
        [[ "$src_file" == *src/backend_scene/src/* || "$src_file" == *src/backend_scene/qml_helper/* ]] || continue
        [[ "$src_file" =~ $MULL_TU_EXCLUDE_RE ]] && continue
        [[ "$line" == *"-fpass-plugin"* ]] && continue
        missing+=("$src_file")
    done <<< "$cmds"
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "first-party translation unit(s) built without Mull's -fpass-plugin for $t:"
        printf '  %s\n' "${missing[@]}" >&2
        fail "$t links first-party code Mull never instrumented — call wek_apply_mull_instrumentation() on the owning library target"
    fi
}

# run_mull_pass <target> <bin> <target_dir> <mull-config> <label> -- runs one
# Mull invocation against <bin> under MULL_CONFIG=<mull-config>, normalising
# whatever it reports into <target_dir>/{survivors,killed}.json.  Split out of
# the main per-target loop so the added-files pass (a second config, a
# second report dir, same binary) can reuse it exactly rather than drifting
# from the primary pass over time.  <label> is appended to log lines so the
# two passes over one target are distinguishable in output.
run_mull_pass() {
    local t="$1" bin="$2" target_dir="$3" cfg="$4" label="${5:-}"
    mkdir -p "$target_dir"
    export MULL_CONFIG="$cfg"
    ok "mull config: $MULL_CONFIG"
    # Strip whatever absolute prefix lands the path at the repo root so the
    # baseline survives different checkout locations and the Bazzite
    # /home <-> /var/home symlink (distrobox sees /home, host pwd lands at
    # /var/home).  Anchors on the leaf dir name "wallpaper-engine-kde-plugin/"
    # which mull's report consistently embeds.  Survivors that don't match
    # the leaf (none expected today) pass through unchanged.  Submodule paths
    # come out as src/backend_scene/src/... after this substitution.
    local repo_leaf rpt out
    repo_leaf="$(basename "$(pwd)")"
    if [[ "$USE_ELEMENTS" == "1" ]]; then
        # Elements writes <epoch>.json into --report-dir.
        # --no-output skips capturing test stdout/stderr from each mutant — Mull
        # otherwise attaches GDB to every "failing" mutant for post-mortem (which
        # for our purposes is most of them, since killed mutants ARE the success
        # case).  Cuts per-mutant overhead by ~5x.
        if ! ( ulimit -v $((MULL_MUTANT_AS_MB * 1024))
               exec "$RUNNER" --workers "$MULL_WORKERS" \
                       --timeout "$MULL_TIMEOUT_MS" \
                       --minimum-timeout "$MULL_MIN_TIMEOUT_MS" \
                       --no-output \
                       --reporters Elements \
                       --report-dir "$target_dir" \
                       --report-name report \
                       "$bin" ) 2>&1 | tee "$target_dir/runner.log" | tail -8; then
            warn "Mull exit nonzero for $t$label (survivors expected; output captured)"
        fi
        rpt=$(find "$target_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1 || true)
        if [[ -z "$rpt" || ! -s "$rpt" ]]; then
            # Mull writes no report when the diff holds no mutable lines, which a
            # build-system or comment-only change produces routinely.  That is a
            # clean measurement of nothing, not a failure to measure -- and only
            # Mull's own message separates the two, so read it rather than
            # inferring from the missing file.
            if grep -qi 'No mutants found' "$target_dir/runner.log" 2>/dev/null; then
                ok "$t$label: no mutants in scope for this diff — nothing to measure"
                printf '[]\n' > "$target_dir/survivors.json"
                printf '[]\n' > "$target_dir/killed.json"
                ANY_REPORT=1
                return 0
            fi
            warn "no Elements report for $t$label — skipping in aggregate"
            return 0
        fi
        ANY_REPORT=1
        # Normalise Elements: .files{path => {source, mutants: [{id, mutatorName, location, status}]}}
        # MOC ignore applied here so the baseline never accumulates Qt autogen noise.
        # line_text comes from $e.value.source, which Elements embeds per file;
        # see line_text_of() in JQ_LIB for why it is trimmed and whitespace-collapsed.
        jq --arg leaf "$repo_leaf" --arg moc "$MOC_IGNORE" "$JQ_LIB"'
          [ .files | to_entries[] as $e
            | $e.value.mutants[]
            | select(.status == "Survived" or .status == "survived")
            | {file: ($e.key | sub("^.*/"+$leaf+"/"; "")),
               line: (.location.start.line // 0),
               mutator: (.mutatorName // .mutator // "unknown"),
               line_text: line_text_of($e.value; .location.start.line;
                                       (.location.end.line // .location.start.line // 0))}
            | select(.file | test($moc) | not) ]
        ' "$rpt" > "$target_dir/survivors.json"
        # The same mutant seen by a target that DOES cover it.  Timeout counts:
        # a mutant that hangs the suite has been detected just as surely as one
        # that fails an assertion.
        jq --arg leaf "$repo_leaf" --arg moc "$MOC_IGNORE" "$JQ_LIB"'
          [ .files | to_entries[] as $e
            | $e.value.mutants[]
            | select((.status // "") | ascii_downcase | . == "killed" or . == "timeout")
            | {file: ($e.key | sub("^.*/"+$leaf+"/"; "")),
               line: (.location.start.line // 0),
               mutator: (.mutatorName // .mutator // "unknown"),
               line_text: line_text_of($e.value; .location.start.line;
                                       (.location.end.line // .location.start.line // 0))}
            | select(.file | test($moc) | not) ]
        ' "$rpt" > "$target_dir/killed.json"
    else
        # IDE reporter: prints "path/file.cpp:line:col: <mutator> Survived" lines,
        # with no per-file source text to slice a line_text out of -- entries from
        # this path carry {file,line,mutator} only, which degrades matching to the
        # pre-line_text behaviour (null equals null on both sides of a comparison).
        # Mull is pinned at 0.31.1 (src/backend_scene/cmake/FetchMull.cmake), which
        # supports --reporters=Elements, so this fallback is not expected to fire
        # in this project's build environments; it exists for a Mull that predates
        # Elements support.
        out="$target_dir/ide.log"
        ( ulimit -v $((MULL_MUTANT_AS_MB * 1024))
          exec "$RUNNER" --workers "$MULL_WORKERS" \
                  --timeout "$MULL_TIMEOUT_MS" \
                  --minimum-timeout "$MULL_MIN_TIMEOUT_MS" \
                  --reporters IDE "$bin" ) 2>&1 | tee "$out" | tail -8 || true
        # The IDE reporter has no missing-file tell: jq turns an empty log into
        # an empty survivor list, which reads as a clean run.  A fatal Mull
        # error (a timed-out warmup being the usual one) must not surface as
        # "no new survivors".
        if [[ ! -s "$out" ]] || grep -q 'treated as fatal errors' "$out"; then
            warn "Mull failed before reporting for $t$label — skipping in aggregate"
            return 0
        fi
        ANY_REPORT=1
        jq -nR --arg leaf "$repo_leaf" --arg moc "$MOC_IGNORE" '
          [inputs
           | capture("(?<file>[^:]+):(?<line>[0-9]+):.*\\s(?<mutator>cxx_[a-z_]+|negate_cond)\\s+Survived")
           | {file: (.file | sub("^.*/"+$leaf+"/"; "")),
              line: (.line|tonumber),
              mutator}
           | select(.file | test($moc) | not)]
        ' < "$out" > "$target_dir/survivors.json"
    fi
}

[[ "$AGGREGATE_ONLY" == "1" ]] && TARGETS=()
for t in "${TARGETS[@]}"; do
    bin="$(bin_path "$t")"
    if [[ ! -x "$bin" ]]; then
        warn "missing $bin — skipping"
        continue
    fi
    ANY_BIN=1
    check_mull_instrumentation "$t" "$bin"

    target_dir="$OUT_DIR/$t${OUT_SUFFIX:+-$OUT_SUFFIX}"
    step "mutating $t ($bin)"
    # Called directly, NOT as MULL_CONFIG="$(mull_config_for "$t")": a command
    # substitution would run the function in a subshell, and _MULL_CFG_ROOT/
    # _MULL_CFG_REF (which the added-files pass below depends on) would be
    # lost the moment that subshell exited.
    mull_config_for "$t"
    MULL_CONFIG="$_MULL_CFG_PATH"
    if [[ -z "$MULL_CONFIG" ]]; then
        # Without a config Mull mutates third_party and the test sources too:
        # far more mutants, and a baseline full of entries for code we neither
        # own nor test.  Refuse rather than quietly produce a different
        # measurement that still looks like a clean run.
        fail "no mull.yml resolved for $t — refusing to mutate it unfiltered"
    fi
    run_mull_pass "$t" "$bin" "$target_dir" "$MULL_CONFIG" ""

    # A diff-scoped run can't see a file the base ref never had -- Mull's own
    # git filter finds no delta for a path absent from the base tree, so a
    # brand-new file's mutants never reach the pass above no matter how much
    # arithmetic/comparison logic it holds.  Measure those files in full, as a
    # second pass into their own report dir; the aggregation glob below reads
    # every subdirectory under $OUT_DIR, so both passes merge automatically.
    if [[ "$MODE" == "diff" ]]; then
        ADDED_CONFIG="$(mull_added_files_config_for "$t")"
        if [[ -n "$ADDED_CONFIG" ]]; then
            # Underscore, not hyphen: the report-dir basename becomes part of a
            # bash variable name in the gate's own hermetic self-test (which
            # picks a stub runner's canned report by ${!STUB_REPORT_<basename>}),
            # and a hyphen there is not a legal identifier character.
            added_dir="$OUT_DIR/$t${OUT_SUFFIX:+-$OUT_SUFFIX}_added"
            step "mutating $t ($bin) — files added since the diff base"
            run_mull_pass "$t" "$bin" "$added_dir" "$ADDED_CONFIG" " (added files)"
        fi
    fi
done

if [[ "$AGGREGATE_ONLY" == "1" ]]; then
    if ! compgen -G "$OUT_DIR/*/survivors.json" >/dev/null; then
        fail "--aggregate-only: no chunk reports under $OUT_DIR — nothing to aggregate"
    fi
    ANY_BIN=1
    ANY_REPORT=1
    ok "aggregating existing reports: $(compgen -G "$OUT_DIR/*/survivors.json" | wc -l) chunk(s)"
fi

if [[ "$ANY_BIN" == "0" ]]; then
    fail "no mutation-instrumented binaries found in $BUILD/ or $BUILD_SUB/ — did MUTATION_TESTING configure correctly?"
fi

# Every target ran and none reported.  Exit 78 rather than diffing an empty
# aggregate against the baseline: "we could not measure" and "the code got
# worse" deserve different answers, and only the second should ever block.
if [[ "$ANY_REPORT" == "0" ]]; then
    warn "no target produced a mutation report — the survivor diff would be meaningless"
    warn "usual cause: the instrumented warmup run exceeded ${MULL_TIMEOUT_MS}ms (raise MULL_TIMEOUT_MS)"
    exit 78
fi

# ── Aggregate + dedupe survivors across targets ───────────────────────────────
# Shape: { survivors: [ {file, line, mutator, line_text}, ... ] }
# A mutant is dead if ANY target killed it.  Several binaries link the same
# translation unit -- a test for one class pulls in a helper .cpp for a single
# function -- so the same mutant is offered to suites that never execute that
# line.  Unioning the per-target survivor lists therefore reports mutants the
# owning suite kills, which reads as a regression and is really a binary being
# asked about code it does not test.  Subtract what was killed anywhere.
#
# Both this union and the killed union below merge via fold_merge/subtract_dead
# (JQ_LIB) -- matching on {file, mutator, line_text} with a nearest-line
# tie-break -- rather than an exact {file, line, mutator} key.  A chunked
# sweep (--no-wipe / --aggregate-only) can span a code edit between chunks; an
# exact-line key would then count one physical mutant, reported by two chunks
# at two different lines, as two.
KILLED_JSON="$OUT_DIR/killed-any.json"
if compgen -G "$OUT_DIR/*/killed.json" >/dev/null; then
    jq -s "$JQ_LIB"'fold_merge(.)' "$OUT_DIR"/*/killed.json > "$KILLED_JSON"
else
    echo '[]' > "$KILLED_JSON"
fi
jq -s "$JQ_LIB"'
  fold_merge(.) as $union
  | { survivors: (subtract_dead($union; $killed[0]) | sort_by([.file, .line, .mutator])) }
' --slurpfile killed "$KILLED_JSON" "$OUT_DIR"/*/survivors.json > "$OUT_DIR/all.json"
COUNT=$(jq '.survivors | length' "$OUT_DIR/all.json")
ok "aggregated $COUNT surviving mutant(s)"

# Handing Mull a config and having it honour one are different things, and the
# only externally visible difference is which paths show up in the results.  The
# submodule config excludes third_party and the test sources, so a survivor from
# either means mull.yml was never read -- the defect that had this gate mutating
# doctest.h and its own tests while still reporting a tidy verdict.  Checked in
# every mode, because a refresh that ran unfiltered would bake the noise into the
# baseline and make the next run look clean.
STRAY="$(jq -r '
  .survivors[]
  | select(.file | test("src/backend_scene/(third_party|src/Test)/"))
  | "  \(.file):\(.line) [\(.mutator)]"
' "$OUT_DIR/all.json" | head -10 || true)"
if [[ -n "$STRAY" ]]; then
    warn "survivors from paths src/backend_scene/mull.yml excludes:"
    printf '%s\n' "$STRAY" >&2
    fail "excluded paths were mutated — Mull did not read its config (MULL_CONFIG did not reach it)"
fi

# Files this run actually mutated (survived OR killed, by any target) -- used
# both to scope --refresh-baseline (never touch a file no target here
# measured) and to decide whether a stale baseline entry can honestly be
# called "resolved" rather than merely unmeasured this run.
SCOPE_FILES_JSON="$OUT_DIR/scope-files.json"
if compgen -G "$OUT_DIR/*/survivors.json" >/dev/null; then
    jq -s '[ .[][] | .file ] | unique' "$OUT_DIR"/*/survivors.json "$OUT_DIR"/*/killed.json \
        > "$SCOPE_FILES_JSON"
else
    echo '[]' > "$SCOPE_FILES_JSON"
fi

if [[ ! -s "$BASELINE" && "$REFRESH" != "1" ]]; then
    warn "no baseline yet — run tools/scripts/mutation.sh --refresh-baseline to seed"
    exit 0
fi

# ── Compare against the baseline: new / moved / killed ────────────────────────
# Matches on {file, mutator, line_text} rather than {file, line, mutator}: an
# edit that inserts a line above a baseline entry shifts its line number but
# not its identity, and re-keying on the raw line orphans it -- reported as a
# brand-new survivor at the shifted line while the stale entry rots at the old
# one, unable to ever match anything again.  The reverse also happens: two
# DIFFERENT mutants can legitimately share a line and mutator (an edit that
# changes that exact expression's operands without moving it), and matching
# on {file,mutator} alone -- ignoring the text -- would treat that as no
# change at all.  Duplicate text at different lines (real in this codebase --
# ThumbnailGrabber.cpp has the same `else if (... MPV_EVENT_END_FILE)` guard
# twice) is resolved by nearest-line tie-break rather than by whichever one jq
# sees first.
BASE_SURVIVORS_JSON="$( [[ -s "$BASELINE" ]] && jq -c '.survivors // []' "$BASELINE" || echo '[]' )"
CMP="$(jq -n "$JQ_LIB"'
  match_all($base; $cur) as $m
  | { new: $m.leftover_c,
      moved: [ $m.pairs[] | select(.b.line != .c.line) ],
      killed: [ $m.leftover_b[] | select(.file as $f | $scope | index($f) != null) ] }
' --argjson base "$BASE_SURVIVORS_JSON" \
  --argjson cur "$(jq -c '.survivors' "$OUT_DIR/all.json")" \
  --argjson scope "$(cat "$SCOPE_FILES_JSON")")"

# `|| true` on every head-piped listing below: head closes the pipe once it
# has enough lines, jq takes SIGPIPE, and under `set -euo pipefail` that used
# to kill the script with 141 before it reached its own verdict -- so a
# strict run reported a signal instead of the survivor failure it had just
# computed.
MOVED_N=$(jq '.moved | length' <<<"$CMP")
if [[ "$MOVED_N" -gt 0 ]]; then
    warn "$MOVED_N baseline entry/entries moved (same mutant, different line):"
    jq -r '.moved[] | "  moved: \(.b.file) [\(.b.mutator)] line \(.c.line), was line \(.b.line)"' \
        <<<"$CMP" | head -25 || true
fi

KILLED_N=$(jq '.killed | length' <<<"$CMP")
if [[ "$KILLED_N" -gt 0 ]]; then
    ok "$KILLED_N baseline entry/entries no longer survive:"
    jq -r '.killed[] | "  \(.file):\(.line) [\(.mutator)] no longer survives (baseline entry not reproduced)"' \
        <<<"$CMP" | head -25 || true
fi

if [[ "$REFRESH" == "1" ]]; then
    # Scope-safe merge: a baseline entry for a file this run did not mutate is
    # left exactly as it was.  A full sweep (no --target/--diff-only) mutates
    # every file the baseline could possibly cite, so $out_of_scope comes back
    # empty and this degrades to the old whole-file overwrite -- the common
    # case is unchanged.  A --target or --diff-only refresh instead merges:
    # only the files it actually measured are replaced by what it measured.
    OLD_JSON="$( [[ -s "$BASELINE" ]] && cat "$BASELINE" || echo '{}' )"
    OLD_COUNT=$(jq '.survivors // [] | length' <<<"$OLD_JSON")
    jq '
      (.survivors // []) as $old
      | ($old | map(select(.file as $f | ($scope | index($f)) == null))) as $out_of_scope
      | . + {survivors: ($out_of_scope + $cur | sort_by([.file, .line, .mutator])),
             _comment: "Surviving mutants accepted as baseline. Run tools/scripts/mutation.sh --refresh-baseline to update; new entries in a non-refresh run fail the gate."}
    ' --argjson scope "$(cat "$SCOPE_FILES_JSON")" \
      --argjson cur "$(jq -c '.survivors' "$OUT_DIR/all.json")" \
      <<<"$OLD_JSON" > "$BASELINE"
    ok "baseline refreshed (scope-safe): $BASELINE ($(jq '.survivors | length' "$BASELINE") survivors, $OLD_COUNT before)"
    exit 0
fi

N=$(jq '.new | length' <<<"$CMP")
if [[ "$N" -gt 0 ]]; then
    warn "$N new surviving mutant(s):"
    jq -r '.new[] | "  \(.file):\(.line) [\(.mutator)]"' <<<"$CMP" | head -25 || true
    if [[ "$STRICT" == "1" ]]; then
        fail "$N new surviving mutant(s) — review and either fix code or run --refresh-baseline"
    fi
    warn "informational (--no-strict) — gate disabled for this run"
    exit 0
fi
ok "no new surviving mutants vs baseline"
