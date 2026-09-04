#!/usr/bin/env bash
# tools/scripts/mutation-sweep.sh — a full mutation baseline, in resumable pieces.
#
# Why this exists: backend_scene_tests carries ~3700 mutants and each one re-runs
# the whole suite (~91s instrumented), so a single sweep is many hours.  On a
# desktop that is not a background job you can walk away from -- systemd-oomd
# kills the session slice under sustained memory pressure, and any interruption
# of a monolithic run throws away everything it had measured.
#
# So the sweep runs in chunks whose reports accumulate side by side under
# $OUT_DIR.  An interrupted run loses at most the chunk in flight; re-invoking
# picks up where it stopped.  The baseline is still written by mutation.sh from
# the accumulated reports, so it is machine-generated, not hand-assembled.
#
#   tools/scripts/mutation-sweep.sh                # run/resume, then write baseline
#   tools/scripts/mutation-sweep.sh --budget 200   # mutants per chunk (default 150)
#   tools/scripts/mutation-sweep.sh --status       # what is done, what is left
#   tools/scripts/mutation-sweep.sh --finish       # aggregate + write baseline now
#   tools/scripts/mutation-sweep.sh --restart      # discard progress and start over
#
# Pressure, not free RAM, is what kills long runs here, so keep MULL_MAX_WORKERS
# where it is.  If you do watch it, watch the right file: systemd-oomd acts on
# the *cgroup's* memory.pressure, under
#   /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/…
# and NOT the system-wide /proc/pressure/memory, which sat at 0.00 for the two
# hours leading up to a kill.
set -euo pipefail

_SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
cd "${_SUPER:-$(git rev-parse --show-toplevel)}"

MUTATION="$_SWEEP_DIR/mutation.sh"

# Bound our own memory before doing anything else.
#
# Mutation testing runs deliberately broken code: a mutant that corrupts a size
# or a loop bound allocates pathologically, and several of those at once take the
# machine with them.  Observed twice -- once as a systemd-oomd pressure kill, once
# as a kernel *global* OOM (`constraint=CONSTRAINT_NONE, global_oom`) that picked
# the test binary as its victim and failed the whole session unit.  Neither was a
# cgroup limit catching anything, because this slice has `memory.max = max`.
#
# Under a scope the kernel reclaims and then kills *inside* the scope, so a
# runaway mutant dies alone and Mull records it as killed -- which is the correct
# result for it anyway -- instead of the desktop losing an unrelated application.
if [[ -z "${WEK_SWEEP_SCOPED:-}" ]] && command -v systemd-run >/dev/null 2>&1; then
    export WEK_SWEEP_SCOPED=1
    exec systemd-run --user --scope --quiet --collect \
        --unit="wek-mutation-sweep-$$" \
        -p MemoryHigh="${WEK_SWEEP_MEM_HIGH:-6G}" \
        -p MemoryMax="${WEK_SWEEP_MEM_MAX:-8G}" \
        -- "${BASH_SOURCE[0]}" "$@"
fi

BUILD="build/impl-mutation"
BUILD_SUB="build/impl-mutation-sub"
OUT_DIR="$BUILD/mull-out"
SWEEP="$OUT_DIR/sweep"
DONE_FILE="$SWEEP/done.txt"
PLAN_DIR="$SWEEP/chunks"
DRY="$SWEEP/dry.json"
SUB_TARGET="backend_scene_tests"
SUB_BIN="$BUILD_SUB/src/Test/$SUB_TARGET"

BUDGET=150
ACTION="run"
while (( $# )); do
    case "$1" in
        --budget)  BUDGET="$2"; shift 2 ;;
        --status)  ACTION="status"; shift ;;
        --finish)  ACTION="finish"; shift ;;
        --restart) ACTION="restart"; shift ;;
        --help|-h) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    GREEN=$'\033[1;32m'; BLUE=$'\033[1;34m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
else
    GREEN=""; BLUE=""; YELLOW=""; RED=""; RESET=""
fi
step() { printf '\n%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  warn%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf '\n%sFAIL:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

if [[ "$ACTION" == "restart" ]]; then
    rm -rf "$SWEEP"
    ok "sweep state discarded — the next run starts from scratch"
    exit 0
fi

mkdir -p "$SWEEP" "$PLAN_DIR"
touch "$DONE_FILE"

# ── Plan: discover every mutant once, then pack files into chunks ─────────────
# A dry run reports the mutants without executing any, which is how the sweep
# learns its own size.  Mull is given the real config here so excludePaths apply
# -- planning against unfiltered output would build chunks for vendored code the
# actual runs then refuse to mutate, and every one of those chunks would look
# like it silently measured nothing.
plan() {
    [[ -x "$SUB_BIN" ]] || fail "no instrumented $SUB_BIN — run tools/scripts/mutation.sh --target $SUB_TARGET once first"
    if [[ ! -s "$DRY" ]]; then
        step "Planning: discovering mutants (dry run, no execution)"
        local runner
        runner="$(find "$BUILD" "$BUILD_SUB" -path '*/_mull/*' -name 'mull-runner*' -executable 2>/dev/null | head -1 || true)"
        [[ -n "$runner" ]] || fail "mull-runner not found under $BUILD/ or $BUILD_SUB/"
        MULL_CONFIG="$PWD/src/backend_scene/mull.yml" "$runner" \
            --dry-run --workers 4 --timeout 300000 --minimum-timeout 5000 \
            --no-output --reporters Elements \
            --report-dir "$SWEEP" --report-name dry "$SUB_BIN" >/dev/null 2>&1 || true
        local produced
        produced="$(find "$SWEEP" -maxdepth 1 -name '*.json' -newer "$DONE_FILE" 2>/dev/null | head -1 || true)"
        [[ -z "$produced" ]] && produced="$(find "$SWEEP" -maxdepth 1 -name 'dry*.json' | head -1 || true)"
        [[ -n "$produced" ]] || fail "dry run produced no report — is the warmup exceeding the timeout?"
        [[ "$produced" != "$DRY" ]] && mv "$produced" "$DRY"
        ok "mutant inventory: $DRY"
    fi

    if ! compgen -G "$PLAN_DIR/*.paths" >/dev/null; then
        step "Planning: packing files into chunks of ~$BUDGET mutants"
        python3 - "$DRY" "$PLAN_DIR" "$BUDGET" <<'PY'
import json, sys, os, re
dry, plan_dir, budget = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(dry))
# repo-relative path -> mutant count
counts = {}
for path, v in d.get('files', {}).items():
    rel = path.split('wallpaper-engine-kde-plugin/', 1)[-1]
    counts[rel] = counts.get(rel, 0) + len(v.get('mutants', []))
# Biggest first so one enormous file cannot straddle a chunk boundary and make
# the last chunk enormous; a file always lands whole in exactly one chunk.
items = sorted(counts.items(), key=lambda kv: -kv[1])
chunks, cur, cur_n = [], [], 0
for rel, n in items:
    if cur and cur_n + n > budget:
        chunks.append(cur); cur, cur_n = [], 0
    cur.append((rel, n)); cur_n += n
if cur:
    chunks.append(cur)
for i, ch in enumerate(chunks, 1):
    with open(os.path.join(plan_dir, f'{i:03d}.paths'), 'w') as f:
        for rel, _ in ch:
            f.write('.*/' + re.escape(rel) + '$\n')
total = sum(counts.values())
print(f'{total} mutants across {len(counts)} files -> {len(chunks)} chunks')
PY
    fi
}

chunk_ids() { compgen -G "$PLAN_DIR/*.paths" | xargs -r -n1 basename | sed 's/\.paths$//' | sort; }
is_done()   { grep -qxF "$1" "$DONE_FILE" 2>/dev/null; }

status() {
    local all done_n=0 left=()
    mapfile -t all < <(chunk_ids)
    for c in "${all[@]}"; do
        if is_done "$c"; then done_n=$((done_n + 1)); else left+=("$c"); fi
    done
    printf 'chunks: %d total, %d done, %d remaining\n' "${#all[@]}" "$done_n" "${#left[@]}"
    [[ ${#left[@]} -gt 0 ]] && printf 'next: %s\n' "${left[0]}"
    return 0
}

finish() {
    step "Aggregating every chunk report into the baseline"
    "$MUTATION" --aggregate-only --refresh-baseline
}

case "$ACTION" in
    status) plan >/dev/null 2>&1 || true; status; exit 0 ;;
    finish) finish; exit 0 ;;
esac

plan
status

# ── Run the parent targets once, so the baseline covers them too ─────────────
# Each target is named explicitly.  Invoking mutation.sh with no --target leaves
# it in full mode, whose target list includes backend_scene_tests -- so a step
# meant to take ten minutes silently becomes the entire unchunked sweep, which
# is the one thing this script exists to avoid.  The list comes from
# --list-targets so it cannot drift from ALL_TARGETS.
if ! is_done "parent"; then
    step "Parent targets (one pass each)"
    mapfile -t PARENT_TARGETS < <("$MUTATION" --list-targets | grep -vxF "$SUB_TARGET")
    [[ ${#PARENT_TARGETS[@]} -gt 0 ]] || fail "could not resolve the parent target list"
    parent_ok=0
    for pt in "${PARENT_TARGETS[@]}"; do
        printf '    %s\n' "$pt"
        # Logged, not discarded: sending this to /dev/null is what hid the run
        # above going for two hours without banking anything.
        MUTATION_SKIP_BUILD=1 "$MUTATION" --target "$pt" --no-strict --no-wipe \
            >> "$SWEEP/parent.log" 2>&1 || true
        [[ -s "$OUT_DIR/$pt/survivors.json" ]] && parent_ok=$((parent_ok + 1))
    done
    if [[ "$parent_ok" -gt 0 ]]; then
        echo parent >> "$DONE_FILE"
        ok "parent targets measured ($parent_ok of ${#PARENT_TARGETS[@]} reported)"
    else
        warn "no parent target reported — see $SWEEP/parent.log"
    fi
fi

# ── Submodule chunks ─────────────────────────────────────────────────────────
mapfile -t ALL < <(chunk_ids)
for c in "${ALL[@]}"; do
    is_done "$c" && continue
    step "Chunk $c of ${#ALL[@]}"
    if MUTATION_SKIP_BUILD=1 "$MUTATION" \
            --target "$SUB_TARGET" \
            --include-paths "$(paste -sd, "$PLAN_DIR/$c.paths")" \
            --out-suffix "chunk$c" \
            --no-wipe --no-strict; then
        :
    fi
    # A chunk counts as done only if it left a report behind.  Anything else --
    # a timed-out warmup, an oomd kill, a missing config -- must not be recorded
    # as measured, or the baseline silently loses that slice of the tree.
    if [[ -s "$OUT_DIR/$SUB_TARGET-chunk$c/survivors.json" ]]; then
        echo "$c" >> "$DONE_FILE"
        ok "chunk $c recorded"
    else
        fail "chunk $c produced no report — nothing recorded, re-run to retry it"
    fi
done

status
finish
