#!/usr/bin/env bash
# scripts/mutation.sh — Mull-driven mutation testing for parent C++ tests.
#
# Usage:
#   scripts/mutation.sh                          # full run, diff vs baseline
#   scripts/mutation.sh --diff-only              # run only on changed-file binaries
#   scripts/mutation.sh --refresh-baseline       # rebuild + overwrite tests/.mull-baseline.json
#   scripts/mutation.sh --target tst_filehelper  # one binary
#   scripts/mutation.sh --strict                 # treat new survivors as fatal (rc=1, default)
#   scripts/mutation.sh --no-strict              # informational mode (rc=0 even with new survivors)
#   scripts/mutation.sh --help                   # this help
#
# Baseline diff:
#   New survivors (in current run but not baseline) -> fail (rc=1) unless --no-strict.
#   Killed previously-accepted survivors -> informational note (does not fail).
#
# Build: configure+build with -DMUTATION_TESTING=ON in build/impl-mutation/.
# Runner: discovered dynamically — host-PATH mull-runner-NN preferred, then the
# binary fetched into build/impl-mutation/_mull/usr/bin/.
#
# NOT wired into the default preflight gate (heavy: full run ≈ 10-15 min). Run
# separately when you want the gate; preflight stays focused on the fast checks.
#
# Exit codes: 0=clean / 1=new survivors / 2=arg error / 77=runner or build unavailable.
set -euo pipefail

# Resolve to the parent repo's working tree even when invoked from inside the
# `src/backend_scene` submodule (mirrors scripts/preflight.sh).
_SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
cd "${_SUPER:-$(git rev-parse --show-toplevel)}"

BUILD="build/impl-mutation"
OUT_DIR="$BUILD/mull-out"
BASELINE="tests/.mull-baseline.json"

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
            sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ── Tool preflight ────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null; then
    fail "jq not found on host — install with 'sudo dnf install jq' (or your distro equivalent)"
fi

# ── Configure + build ─────────────────────────────────────────────────────────
step "Configure + build with -DMUTATION_TESTING=ON"
# Fresh build dir keeps coverage / mutation flag combinations from clashing.
if [[ ! -f "$BUILD/CMakeCache.txt" ]]; then
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B $BUILD -S tests -G Ninja \
                -DMUTATION_TESTING=ON -DCMAKE_BUILD_TYPE=Debug" \
        || fail "mutation configure failed"
fi
dbox "cmake --build $BUILD -j" || fail "mutation build failed"
ok "mutation build complete"

# ── Discover the mull-runner ─────────────────────────────────────────────────
# Pin version suffix lives in FetchMull.cmake only; this driver follows whatever
# the fetched build dir exposed.
RUNNER=""
for candidate in \
    "$BUILD/_mull/usr/bin/mull-runner-21" \
    "$BUILD/_mull/usr/bin/mull-runner-22" \
    "$BUILD/_mull/usr/bin/mull-runner" \
; do
    if [[ -x "$candidate" ]]; then RUNNER="$candidate"; break; fi
done
if [[ -z "$RUNNER" ]]; then
    # Fall back to PATH / wildcard scan of _deps and _mull.
    if RUNNER=$(command -v mull-runner-21 || command -v mull-runner-22 \
                || command -v mull-runner 2>/dev/null) \
       && [[ -x "$RUNNER" ]]; then
        :
    else
        RUNNER=$(find "$BUILD" -path '*/_mull/*' -name 'mull-runner*' -executable 2>/dev/null \
                  | head -1 || true)
    fi
fi
if [[ -z "$RUNNER" || ! -x "$RUNNER" ]]; then
    warn "mull-runner unavailable — rebuild with -DMUTATION_TESTING=ON or install Mull"
    exit 77
fi
ok "runner: $RUNNER"

# ── Determine target list ─────────────────────────────────────────────────────
# ALL_TARGETS lists every instrumented binary present in tests/CMakeLists.txt's
# MUTATION_TESTING blocks (see :79-443).  Missing-on-disk targets are skipped
# silently — gracefully handles optional deps (libmpv, Qt6 components) that
# leave a target unbuilt.
ALL_TARGETS=(
    tst_filehelper tst_weburlinterceptor tst_plugininfo
    tst_mpriscolors tst_mousegrabber tst_ttyswitchmonitor
    tst_screensavermonitor tst_mpvbackend tst_thumbnail_grabber
    tst_webaudio tst_safewallpaperbridge tst_migrationhelper
    tst_playlist_manager
)
TARGETS=()
if [[ -n "$TARGET" ]]; then
    TARGETS=("$TARGET")
elif [[ "$MODE" == "diff" ]]; then
    # Map changed source paths -> instrumented test target name.  Heuristic:
    # tst_X.cpp tests src/X.{cpp,hpp/.h}; reuse the spec table.  Headers that a
    # mutated TU sees will still trigger the test, but compile-time only sources
    # need explicit mapping; keep this in sync with tests/CMakeLists.txt's
    # MUTATION_TESTING blocks.
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
        t="${SRC_TO_TARGET[$f]:-}"
        [[ -n "$t" ]] && SEEN[$t]=1
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
for t in "${TARGETS[@]}"; do
    bin="$BUILD/$t"
    if [[ ! -x "$bin" ]]; then
        warn "missing $bin — skipping"
        continue
    fi
    ANY_BIN=1
    target_dir="$OUT_DIR/$t"
    mkdir -p "$target_dir"
    step "mutating $t"
    # Strip whatever absolute prefix lands the path at the repo root so the
    # baseline survives different checkout locations and the Bazzite
    # /home <-> /var/home symlink (distrobox sees /home, host pwd lands at
    # /var/home).  Anchors on the leaf dir name "wallpaper-engine-kde-plugin/"
    # which mull's report consistently embeds.  Survivors that don't match
    # the leaf (none expected today) pass through unchanged.
    repo_leaf="$(basename "$(pwd)")"
    if [[ "$USE_ELEMENTS" == "1" ]]; then
        # Elements writes <epoch>.json into --report-dir.
        if ! "$RUNNER" --reporters Elements \
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
        # Normalise Elements: .files{path => {mutants: [{id, mutatorName, location.start.line, status}]}}
        jq --arg leaf "$repo_leaf" '
          [ .files | to_entries[] as $e
            | $e.value.mutants[]
            | select(.status == "Survived" or .status == "survived")
            | {file: ($e.key | sub("^.*/"+$leaf+"/"; "")),
               line: (.location.start.line // 0),
               mutator: (.mutatorName // .mutator // "unknown")} ]
        ' "$rpt" > "$target_dir/survivors.json"
    else
        # IDE reporter: prints "path/file.cpp:line:col: <mutator> Survived" lines.
        out="$target_dir/ide.log"
        "$RUNNER" --reporters IDE "$bin" 2>&1 | tee "$out" | tail -8 || true
        jq -nR --arg leaf "$repo_leaf" '
          [inputs
           | capture("(?<file>[^:]+):(?<line>[0-9]+):.*\\s(?<mutator>cxx_[a-z_]+|negate_cond)\\s+Survived")
           | {file: (.file | sub("^.*/"+$leaf+"/"; "")),
              line: (.line|tonumber),
              mutator}]
        ' < "$out" > "$target_dir/survivors.json"
    fi
done

if [[ "$ANY_BIN" == "0" ]]; then
    fail "no mutation-instrumented binaries found in $BUILD/ — did MUTATION_TESTING configure correctly?"
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

# ── Refresh-or-diff ───────────────────────────────────────────────────────────
if [[ "$MODE" == "refresh" ]]; then
    jq '. + {_comment: "Surviving mutants accepted as baseline. Run scripts/mutation.sh --refresh-baseline to update; new entries in a non-refresh run fail the gate."}' \
        "$OUT_DIR/all.json" > "$BASELINE"
    ok "baseline refreshed: $BASELINE ($COUNT survivors)"
    exit 0
fi

if [[ ! -s "$BASELINE" ]]; then
    warn "no baseline yet — run scripts/mutation.sh --refresh-baseline to seed"
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
    jq -r '.[] | "  \(.file):\(.line) [\(.mutator)]"' <<<"$NEW" | head -25
    if [[ "$STRICT" == "1" ]]; then
        fail "$N new surviving mutant(s) — review and either fix code or run --refresh-baseline"
    fi
    warn "informational (--no-strict) — gate disabled for this run"
    exit 0
fi
ok "no new surviving mutants vs baseline"
