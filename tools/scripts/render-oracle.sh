#!/usr/bin/env bash
# Headless render ORACLE — self-comparison checks the structural smoke cannot.
#
# Renders the WE-bundled `fantasticcar` default scene headless under Mesa
# lavapipe (CPU Vulkan, no GPU) in DETERMINISTIC mode (fixed dt + seeded RNG +
# frame-exact capture) and asserts two self-comparisons:
#
#   MOTION    frame@early vs frame@late must DIFFER beyond a pixel threshold.
#             Catches the "animation frozen / uniforms never reach the GPU"
#             class (a valid, non-blank, but static frame).  BOTH frames are
#             taken AFTER the renderer warm-up window (first-frame / 2-FIF /
#             particle settle); an early capture inside warm-up would make a
#             frozen scene falsely "move", so FRAME_EARLY is past it (not 0/1/2).
#   WARM==COLD render twice into the SAME cache dir — run 1 cold (populates the
#             SPV cache), run 2 warm (reads it).  The captured frame@late must
#             be BYTE-IDENTICAL.  Catches the "warm/cached path skips a
#             side-effect" class (e.g. textures stripped on the 2nd run).
#
# Self-comparison sidesteps cross-machine FP determinism: we never compare
# against a committed golden, only two outputs from the SAME machine/build.
#
# Usage:
#   tools/scripts/render-oracle.sh                # build + render + assert
#   tools/scripts/render-oracle.sh --no-build     # reuse an existing sceneviewer
#   tools/scripts/render-oracle.sh --keep         # keep captured PPMs
#   ASSETS_DIR=/path/to/wallpaper_engine/assets tools/scripts/render-oracle.sh
#   FRAME_EARLY=30 FRAME_LATE=120 MOTION_MIN_FRAC=0.01 tools/scripts/render-oracle.sh
#
# Exit codes:
#   0   motion AND warm==cold both passed                              (PASS)
#   77  capability missing — lavapipe / display / WE assets / fixture  (SKIP)
#   1   build failed, render failed, or an assertion failed            (FAIL)

set -euo pipefail

# ── locate repo root (works from anywhere, incl. the submodule CWD) ───────────
_SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
REPO_ROOT="${_SUPER:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -z "$REPO_ROOT" ]] && { echo "render-oracle: not inside a git tree" >&2; exit 1; }
cd "$REPO_ROOT"

VIEWER_DIR="$REPO_ROOT/src/backend_scene/standalone_view"
BUILD_DIR="$VIEWER_DIR/build/impl-oracle"
VIEWER_BIN="$BUILD_DIR/sceneviewer"
# All run artifacts live UNDER the build tree (never /tmp or ~/.cache).
WORK_DIR="$BUILD_DIR/_render_oracle"
CACHE_DIR="$WORK_DIR/spv-cache"

# ── tunables (overridable via env) ────────────────────────────────────────────
RES="${RES:-640x360}"
# Both capture points are PAST the renderer warm-up window (see header comment):
# an early frame inside warm-up would make a frozen scene falsely "move".
FRAME_EARLY="${FRAME_EARLY:-30}"
FRAME_LATE="${FRAME_LATE:-120}"
# Motion passes when at least this FRACTION of pixels differ between early/late.
MOTION_MIN_FRAC="${MOTION_MIN_FRAC:-0.01}"

# ── args ──────────────────────────────────────────────────────────────────────
DO_BUILD=1
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --keep)     KEEP=1 ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "render-oracle: unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# ── output helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; BLUE=$'\033[1;34m'
    YELLOW=$'\033[1;33m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; BLUE=""; YELLOW=""; RESET=""
fi
step() { printf '\n%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ok%s   %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  warn%s %s\n' "$YELLOW" "$RESET" "$*"; }
skip() { printf '\n%sSKIP:%s %s\n' "$YELLOW" "$RESET" "$*"; exit 77; }
fail() { printf '\n%sFAIL:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ── 1. capability probe: lavapipe ICD ─────────────────────────────────────────
step "Probe: Mesa lavapipe (CPU Vulkan) ICD"
LVP_ICD="${VK_ICD_FILENAMES:-}"
if [[ -z "$LVP_ICD" || ! -f "$LVP_ICD" ]]; then
    LVP_ICD=$(ls /usr/share/vulkan/icd.d/lvp_icd.*.json 2>/dev/null | head -1 || true)
fi
[[ -z "$LVP_ICD" || ! -f "$LVP_ICD" ]] && \
    skip "no lavapipe ICD (/usr/share/vulkan/icd.d/lvp_icd.*.json) — install Mesa lavapipe"
ok "lavapipe ICD: $LVP_ICD"

# ── 2. capability probe: WE assets dir ────────────────────────────────────────
step "Probe: Wallpaper Engine assets directory"
ASSETS="${ASSETS_DIR:-}"
WE_ROOT=""
if [[ -z "$ASSETS" ]]; then
    for c in \
        "$HOME/.steam/steam/steamapps/common/wallpaper_engine" \
        "$HOME/.local/share/Steam/steamapps/common/wallpaper_engine" \
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/wallpaper_engine"; do
        [[ -d "$c/assets" ]] && { ASSETS="$c/assets"; WE_ROOT="$c"; break; }
    done
else
    WE_ROOT="$(dirname "$ASSETS")"
fi
[[ -z "$ASSETS" || ! -d "$ASSETS" ]] && \
    skip "WE assets dir not found (set ASSETS_DIR=<steamapps>/common/wallpaper_engine/assets)"
ok "assets: $ASSETS"

# ── 3. capability probe: the fantasticcar bundled default scene ───────────────
step "Probe: fantasticcar bundled default scene"
FIXTURE="${WE_ROOT}/projects/defaultprojects/fantasticcar"
[[ -f "$FIXTURE/project.json" && -f "$FIXTURE/fantasticcar.json" ]] || \
    skip "fantasticcar default not found at $FIXTURE (needs a Wallpaper Engine install)"
ok "fixture: $FIXTURE"

# ── 4. capability probe: a windowing display ──────────────────────────────────
step "Probe: windowing display (xvfb-run preferred, else live WAYLAND/X11)"
DISPLAY_MODE=""
if command -v xvfb-run >/dev/null 2>&1; then
    DISPLAY_MODE="xvfb"; ok "xvfb-run present — running truly headless"
elif [[ -n "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}" ]]; then
    DISPLAY_MODE="wayland"; ok "live Wayland display: $WAYLAND_DISPLAY"
elif [[ -n "${DISPLAY:-}" ]]; then
    DISPLAY_MODE="x11"; ok "live X11 display: $DISPLAY"
else
    skip "no display: xvfb-run absent AND no WAYLAND_DISPLAY/DISPLAY"
fi

# ── 5. build the plain GLFW sceneviewer ───────────────────────────────────────
if [[ "$DO_BUILD" == "1" ]]; then
    step "Build plain sceneviewer (Release, build/impl-oracle)"
    CC="${CC:-clang}" CXX="${CXX:-clang++}" \
        cmake -B "$BUILD_DIR" -S "$VIEWER_DIR" -DCMAKE_BUILD_TYPE=Release \
        || fail "cmake configure failed"
    cmake --build "$BUILD_DIR" --target sceneviewer -j"$(nproc)" \
        || fail "sceneviewer build failed"
    ok "sceneviewer built: $VIEWER_BIN"
fi
[[ -x "$VIEWER_BIN" ]] || fail "sceneviewer binary not found ($VIEWER_BIN) — run without --no-build"

# ── 6. render: 3 deterministic frame-exact captures ───────────────────────────
mkdir -p "$WORK_DIR"
COLD_LATE="$WORK_DIR/cold_late.ppm"
WARM_LATE="$WORK_DIR/warm_late.ppm"
WARM_EARLY="$WORK_DIR/warm_early.ppm"
rm -f "$COLD_LATE" "$WARM_LATE" "$WARM_EARLY"

# One viewer invocation.  LP_NUM_THREADS=0 makes llvmpipe single-threaded so the
# rasterizer is deterministic (no worker-thread reduction order).  WAYLAND_DISPLAY
# is unset for xvfb/x11 so GLFW doesn't prefer an absent Wayland socket.
run_viewer() { # $1=frame  $2=out.ppm
    local frame="$1" out="$2"
    local common=( -R "$RES" --deterministic --screenshot-at-frame "$frame" \
                   -C "$CACHE_DIR" -S "$out" "$ASSETS" "$FIXTURE" )
    case "$DISPLAY_MODE" in
        xvfb)
            VK_ICD_FILENAMES="$LVP_ICD" LP_NUM_THREADS=0 \
            xvfb-run -a -s "-screen 0 1280x720x24" \
                env -u WAYLAND_DISPLAY "$VIEWER_BIN" "${common[@]}" ;;
        wayland)
            VK_ICD_FILENAMES="$LVP_ICD" LP_NUM_THREADS=0 \
                "$VIEWER_BIN" "${common[@]}" ;;
        x11)
            VK_ICD_FILENAMES="$LVP_ICD" LP_NUM_THREADS=0 \
                env -u WAYLAND_DISPLAY "$VIEWER_BIN" "${common[@]}" ;;
    esac
}

# COLD: start from an EMPTY cache so the run compiles + populates it.
step "Render COLD frame@$FRAME_LATE ($DISPLAY_MODE, $RES)"
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
rc=0; run_viewer "$FRAME_LATE" "$COLD_LATE" || rc=$?
[[ "$rc" -eq 0 ]] || fail "cold render exited rc=$rc"
[[ -s "$COLD_LATE" ]] || fail "cold render wrote no PPM ($COLD_LATE)"
ok "cold capture: $COLD_LATE"

# WARM: same cache dir, now populated.
step "Render WARM frame@$FRAME_LATE (cache now warm)"
rc=0; run_viewer "$FRAME_LATE" "$WARM_LATE" || rc=$?
[[ "$rc" -eq 0 ]] || fail "warm render exited rc=$rc"
[[ -s "$WARM_LATE" ]] || fail "warm render wrote no PPM ($WARM_LATE)"
ok "warm capture: $WARM_LATE"

# WARM early frame for the motion comparison (same warmth as WARM_LATE).
step "Render WARM frame@$FRAME_EARLY (for motion comparison)"
rc=0; run_viewer "$FRAME_EARLY" "$WARM_EARLY" || rc=$?
[[ "$rc" -eq 0 ]] || fail "early render exited rc=$rc"
[[ -s "$WARM_EARLY" ]] || fail "early render wrote no PPM ($WARM_EARLY)"
ok "early capture: $WARM_EARLY"

# ── 7. assert WARM==COLD: byte-identical ──────────────────────────────────────
step "Assert: warm == cold (byte-identical frame@$FRAME_LATE)"
if cmp -s "$COLD_LATE" "$WARM_LATE"; then
    ok "warm == cold (byte-identical) — no warm/cold side-effect divergence"
else
    # Report HOW different for debugging before failing.
    python3 - "$COLD_LATE" "$WARM_LATE" <<'PY' || true
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
n=min(len(a),len(b)); diff=sum(1 for i in range(n) if a[i]!=b[i])
print(f"  byte diff: {diff}/{n} differing bytes; sizes {len(a)} vs {len(b)}")
PY
    fail "warm != cold — a warm/cached path diverged (LD2-B-class regression)"
fi

# ── 8. assert MOTION: frame@early differs from frame@late ─────────────────────
step "Assert: motion (frame@$FRAME_EARLY differs from frame@$FRAME_LATE by > ${MOTION_MIN_FRAC})"
python3 - "$WARM_EARLY" "$WARM_LATE" "$MOTION_MIN_FRAC" <<'PY' || fail "motion check failed (scene appears frozen, or PPMs unparseable)"
import sys
def read_ppm(path):
    d=open(path,'rb').read()
    assert d[:2]==b'P6', f"{path}: not P6"
    i=2; tok=[]
    while len(tok)<3:
        while i<len(d) and d[i:i+1].isspace(): i+=1
        s=i
        while i<len(d) and not d[i:i+1].isspace(): i+=1
        tok.append(d[s:i])
    i+=1
    w,h,_=int(tok[0]),int(tok[1]),int(tok[2])
    return w,h,d[i:i+w*h*3]
we,he,pe=read_ppm(sys.argv[1]); wl,hl,pl=read_ppm(sys.argv[2])
if (we,he)!=(wl,hl): print(f"  size mismatch {we}x{he} vs {wl}x{hl}"); sys.exit(1)
n=min(len(pe),len(pl))//3
diff=sum(1 for p in range(0,n*3,3) if pe[p:p+3]!=pl[p:p+3])
frac=diff/n if n else 0.0
thresh=float(sys.argv[3])
print(f"  differing pixels: {diff}/{n} = {frac:.4f} (threshold {thresh})")
sys.exit(0 if frac>thresh else 1)
PY
ok "motion present — frame@$FRAME_EARLY differs from frame@$FRAME_LATE above threshold"

# ── 9. cleanup ────────────────────────────────────────────────────────────────
if [[ "$KEEP" == "1" ]]; then
    warn "kept captures under $WORK_DIR"
else
    rm -f "$COLD_LATE" "$WARM_LATE" "$WARM_EARLY"
fi

printf '\n%sRender oracle PASSED (motion + warm==cold).%s\n' "$GREEN" "$RESET"
exit 0
