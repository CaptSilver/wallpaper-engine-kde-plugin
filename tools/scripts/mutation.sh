#!/usr/bin/env bash
# tools/scripts/mutation.sh — Mull-driven mutation testing for parent + submodule C++ tests.
#
# Usage:
#   tools/scripts/mutation.sh                          # full run, diff vs baseline
#   tools/scripts/mutation.sh --diff-only              # run only on changed-file binaries
#   tools/scripts/mutation.sh --refresh-baseline       # rebuild + overwrite tests/.mull-baseline.json
#   tools/scripts/mutation.sh --target tst_filehelper  # one binary
#   tools/scripts/mutation.sh --strict                 # treat new survivors as fatal (rc=1, default)
#   tools/scripts/mutation.sh --no-strict              # informational mode (rc=0 even with new survivors)
#   tools/scripts/mutation.sh --help                   # this help
#
# Baseline diff:
#   New survivors (in current run but not baseline) -> fail (rc=1) unless --no-strict.
#   Killed previously-accepted survivors -> informational note (does not fail).
#
# Builds (two trees, parallel):
#   - Parent:    build/impl-mutation/      with -DMUTATION_TESTING=ON over tests/
#   - Submodule: build/impl-mutation-sub/  with -DBUILD_TESTS=ON -DMUTATION_TESTING=ON
#                over src/backend_scene/.  Only backend_scene_tests is mutation-
#                instrumented (per src/backend_scene/src/Test/CMakeLists.txt:290);
#                scenescript_tests is excluded.
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
# Exit codes: 0=clean / 1=new survivors / 2=arg error / 77=runner or build unavailable.
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

MODE="full"
TARGET=""
STRICT=1
while (( $# )); do
    case "$1" in
        --diff-only)        MODE="diff"; shift ;;
        --refresh-baseline) MODE="refresh"; shift ;;
        --target)           TARGET="$2"; shift 2 ;;
        --strict)           STRICT=1; shift ;;
        --no-strict)        STRICT=0; shift ;;
        --help|-h)
            sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

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

# ── Determine target list (BEFORE builds so we skip unneeded ones) ───────────
# ALL_TARGETS lists every instrumented binary present in tests/CMakeLists.txt's
# MUTATION_TESTING blocks PLUS the single submodule target (backend_scene_tests,
# instrumented by src/backend_scene/src/Test/CMakeLists.txt:290).  Missing-on-
# disk targets are skipped silently — gracefully handles optional deps (libmpv,
# Qt6 components) that leave a target unbuilt.
ALL_TARGETS=(
    tst_filehelper tst_weburlinterceptor tst_plugininfo
    tst_mpriscolors tst_mousegrabber tst_ttyswitchmonitor
    tst_screensavermonitor tst_mpvbackend tst_thumbnail_grabber
    tst_webaudio tst_safewallpaperbridge tst_migrationhelper
    tst_playlist_manager
    backend_scene_tests
)
TARGETS=()
if [[ -n "$TARGET" ]]; then
    TARGETS=("$TARGET")
elif [[ "$MODE" == "diff" ]]; then
    # Map changed source paths -> instrumented test target name.  Heuristic:
    # tst_X.cpp tests src/X.{cpp,hpp/.h}; reuse the spec table.  Headers that a
    # mutated TU sees will still trigger the test, but compile-time only sources
    # need explicit mapping; keep this in sync with tests/CMakeLists.txt's
    # MUTATION_TESTING blocks.  Any change anywhere under src/backend_scene/
    # (including the gitlink in the parent diff) triggers backend_scene_tests;
    # mutation is heavy enough that finer-grained submodule mapping isn't worth
    # the maintenance cost.
    CHANGED="$(git diff --name-only origin/main...HEAD 2>/dev/null \
              || git diff --name-only HEAD~1 2>/dev/null || true)"
    declare -A SRC_TO_TARGET=(
        [src/FileHelper.cpp]=tst_filehelper [src/FileHelper.hpp]=tst_filehelper
        [src/PluginInfo.cpp]=tst_plugininfo [src/PluginInfo.hpp]=tst_plugininfo
        [src/MprisMonitor.cpp]=tst_mpriscolors
        [src/MouseGrabber.cpp]=tst_mousegrabber
        [src/TTYSwitchMonitor.cpp]=tst_ttyswitchmonitor
        [src/ScreenSaverMonitor.cpp]=tst_screensavermonitor
        [src/backend_mpv/MpvBackend.cpp]=tst_mpvbackend
        [src/backend_mpv/ThumbnailGrabber.cpp]=tst_thumbnail_grabber
        [src/WebAudioBridge.cpp]=tst_webaudio
        [src/SafeWallpaperBridge.cpp]=tst_safewallpaperbridge
        [src/MigrationHelper.cpp]=tst_migrationhelper
        [src/MigrationHelper.h]=tst_migrationhelper
        [src/PlaylistManager.cpp]=tst_playlist_manager
        [src/WebUrlInterceptor.cpp]=tst_weburlinterceptor
    )
    declare -A SEEN=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Parent file → explicit target via SRC_TO_TARGET table.
        t="${SRC_TO_TARGET[$f]:-}"
        [[ -n "$t" ]] && SEEN[$t]=1
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
if [[ -z "$RUNNER" || ! -x "$RUNNER" ]]; then
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
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
PROBE_OUT="$("$RUNNER" --help 2>&1 || true)"
USE_ELEMENTS=1
if ! grep -qE '\bElements\b' <<<"$PROBE_OUT"; then
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
# Parent targets deliberately keep today's behaviour: tests/mull.yml declares a
# narrower `mutators` list than the committed baseline was recorded with, so
# adopting it would quietly shrink the mutant set.  That needs a baseline
# refresh and a decision of its own.
mull_config_for() {
    local t="$1" src root ref cfg
    [[ "$t" == "backend_scene_tests" ]] || { printf ''; return; }
    src="$PWD/src/backend_scene/mull.yml"
    root="$PWD/src/backend_scene"
    [[ -f "$src" ]] || { printf ''; return; }
    if [[ "$MODE" != "diff" ]]; then printf '%s' "$src"; return; fi
    # Diff base, resolved inside the submodule -- it has its own history, so the
    # parent's range says nothing about which submodule lines changed.
    ref="$(git -C "$root" rev-parse --verify --quiet origin/main 2>/dev/null || true)"
    [[ -z "$ref" ]] && ref="$(git -C "$root" rev-parse --verify --quiet HEAD~1 2>/dev/null || true)"
    [[ -z "$ref" ]] && { printf '%s' "$src"; return; }
    cfg="$OUT_DIR/mull-$t.yml"
    { cat "$src"; printf '\ngitProjectRoot: %s\ngitDiffRef: %s\n' "$root" "$ref"; } > "$cfg"
    printf '%s' "$cfg"
}

for t in "${TARGETS[@]}"; do
    bin="$(bin_path "$t")"
    if [[ ! -x "$bin" ]]; then
        warn "missing $bin — skipping"
        continue
    fi
    ANY_BIN=1
    target_dir="$OUT_DIR/$t"
    mkdir -p "$target_dir"
    step "mutating $t ($bin)"
    if MULL_CONFIG="$(mull_config_for "$t")" && [[ -n "$MULL_CONFIG" ]]; then
        export MULL_CONFIG
        ok "mull config: $MULL_CONFIG"
    elif [[ "$t" == "backend_scene_tests" ]]; then
        # Without the config Mull mutates third_party and the test sources too:
        # twice the mutants, and a baseline full of entries for code we do not
        # own.  Refuse rather than quietly produce a different measurement.
        fail "src/backend_scene/mull.yml not found — refusing to mutate $t unfiltered"
    else
        unset MULL_CONFIG
    fi
    # Strip whatever absolute prefix lands the path at the repo root so the
    # baseline survives different checkout locations and the Bazzite
    # /home <-> /var/home symlink (distrobox sees /home, host pwd lands at
    # /var/home).  Anchors on the leaf dir name "wallpaper-engine-kde-plugin/"
    # which mull's report consistently embeds.  Survivors that don't match
    # the leaf (none expected today) pass through unchanged.  Submodule paths
    # come out as src/backend_scene/src/... after this substitution.
    repo_leaf="$(basename "$(pwd)")"
    if [[ "$USE_ELEMENTS" == "1" ]]; then
        # Elements writes <epoch>.json into --report-dir.
        # --no-output skips capturing test stdout/stderr from each mutant — Mull
        # otherwise attaches GDB to every "failing" mutant for post-mortem (which
        # for our purposes is most of them, since killed mutants ARE the success
        # case).  Cuts per-mutant overhead by ~5x.
        if ! "$RUNNER" --workers "$MULL_WORKERS" \
                       --timeout "$MULL_TIMEOUT_MS" \
                       --minimum-timeout "$MULL_MIN_TIMEOUT_MS" \
                       --no-output \
                       --reporters Elements \
                       --report-dir "$target_dir" \
                       --report-name report \
                       "$bin" 2>&1 | tail -8; then
            warn "Mull exit nonzero for $t (survivors expected; output captured)"
        fi
        rpt=$(find "$target_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1 || true)
        if [[ -z "$rpt" || ! -s "$rpt" ]]; then
            warn "no Elements report for $t — skipping in aggregate"
            continue
        fi
        ANY_REPORT=1
        # Normalise Elements: .files{path => {mutants: [{id, mutatorName, location.start.line, status}]}}
        # MOC ignore applied here so the baseline never accumulates Qt autogen noise.
        jq --arg leaf "$repo_leaf" --arg moc "$MOC_IGNORE" '
          [ .files | to_entries[] as $e
            | $e.value.mutants[]
            | select(.status == "Survived" or .status == "survived")
            | {file: ($e.key | sub("^.*/"+$leaf+"/"; "")),
               line: (.location.start.line // 0),
               mutator: (.mutatorName // .mutator // "unknown")}
            | select(.file | test($moc) | not) ]
        ' "$rpt" > "$target_dir/survivors.json"
    else
        # IDE reporter: prints "path/file.cpp:line:col: <mutator> Survived" lines.
        out="$target_dir/ide.log"
        "$RUNNER" --workers "$MULL_WORKERS" \
                  --timeout "$MULL_TIMEOUT_MS" \
                  --minimum-timeout "$MULL_MIN_TIMEOUT_MS" \
                  --reporters IDE "$bin" 2>&1 | tee "$out" | tail -8 || true
        # The IDE reporter has no missing-file tell: jq turns an empty log into
        # an empty survivor list, which reads as a clean run.  A fatal Mull
        # error (a timed-out warmup being the usual one) must not surface as
        # "no new survivors".
        if [[ ! -s "$out" ]] || grep -q 'treated as fatal errors' "$out"; then
            warn "Mull failed before reporting for $t — skipping in aggregate"
            continue
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
done

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
# Shape: { survivors: [ {file, line, mutator}, ... ] }
jq -s '
  [ .[][] ]
  | unique_by({file, line, mutator})
  | sort_by([.file, .line, .mutator])
  | {survivors: .}
' "$OUT_DIR"/*/survivors.json > "$OUT_DIR/all.json"
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

# ── Refresh-or-diff ───────────────────────────────────────────────────────────
if [[ "$MODE" == "refresh" ]]; then
    jq '. + {_comment: "Surviving mutants accepted as baseline. Run tools/scripts/mutation.sh --refresh-baseline to update; new entries in a non-refresh run fail the gate."}' \
        "$OUT_DIR/all.json" > "$BASELINE"
    ok "baseline refreshed: $BASELINE ($COUNT survivors)"
    exit 0
fi

if [[ ! -s "$BASELINE" ]]; then
    warn "no baseline yet — run tools/scripts/mutation.sh --refresh-baseline to seed"
    exit 0
fi

# New = in current run but not baseline (keyed on file+line+mutator).
NEW=$(jq -s '
  .[0].survivors as $base
  | .[1].survivors
  | map(. as $s
        | select($base | map({file:.file, line:.line, mutator:.mutator})
                      | index({file:$s.file, line:$s.line, mutator:$s.mutator}) | not))
' "$BASELINE" "$OUT_DIR/all.json")
N=$(jq 'length' <<<"$NEW")
if [[ "$N" -gt 0 ]]; then
    warn "$N new surviving mutant(s):"
    # `|| true`: head closes the pipe at 25 lines, jq takes SIGPIPE, and under
    # `set -euo pipefail` that killed the script with 141 before it could reach
    # its own verdict below -- so a strict run reported a signal instead of the
    # survivor failure it had just computed.
    jq -r '.[] | "  \(.file):\(.line) [\(.mutator)]"' <<<"$NEW" | head -25 || true
    if [[ "$STRICT" == "1" ]]; then
        fail "$N new surviving mutant(s) — review and either fix code or run --refresh-baseline"
    fi
    warn "informational (--no-strict) — gate disabled for this run"
    exit 0
fi
ok "no new surviving mutants vs baseline"
