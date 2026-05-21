#!/usr/bin/env bash
# Headless render smoke test (D10a) — the first automated execution of the
# Vulkan render path.
#
# Builds the plain GLFW `sceneviewer`, renders a tiny bundled fixture scene
# headless under Mesa lavapipe (CPU Vulkan, no GPU), captures a PPM, and asserts
#   (1) the process exits rc==0, and
#   (2) the framebuffer is NON-BLANK (more than one distinct colour / nonzero
#       per-channel range — a black/empty frame fails).
#
# This is the *smoke* form only.  The deterministic golden-HASH form (D10b)
# needs a frame-indexed capture trigger (deferred, spec item D11 P1.2) and is
# intentionally NOT attempted here — captures vary run-to-run (wall-clock
# animation), so any pixel-exact assertion would be flaky.
#
# Usage:
#   scripts/render-smoke.sh                 # build + render + assert non-blank
#   scripts/render-smoke.sh --no-build      # reuse an existing sceneviewer binary
#   scripts/render-smoke.sh --keep          # keep the captured PPM (don't clean up)
#   ASSETS_DIR=/path/to/wallpaper_engine/assets scripts/render-smoke.sh
#
# Exit codes:
#   0   render succeeded AND framebuffer non-blank   (PASS)
#   77  capability missing — lavapipe ICD / display / WE assets absent  (SKIP)
#   1   build failed, render failed (rc!=0), or framebuffer BLANK        (FAIL)
#
# The SKIP code (77, the autotools/ctest convention) lets preflight treat a
# box without lavapipe/Xvfb/WE-assets as "skipped" rather than "failed".
#
# Requirements (all probed; missing → SKIP, never FAIL):
#   - Mesa lavapipe ICD  (/usr/share/vulkan/icd.d/lvp_icd.*.json)
#   - a windowing display: `xvfb-run` (preferred, truly headless) OR an already
#     -present WAYLAND_DISPLAY / DISPLAY (desktop session / live distrobox)
#   - the Wallpaper Engine `assets/` dir (the renderer reads base materials/
#     shaders from it; the fixture references models/util/solidlayer.json)

set -euo pipefail

# ── locate repo root (works from anywhere, incl. the submodule CWD) ───────────
_SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
REPO_ROOT="${_SUPER:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -z "$REPO_ROOT" ]] && { echo "render-smoke: not inside a git tree" >&2; exit 1; }
cd "$REPO_ROOT"

VIEWER_DIR="$REPO_ROOT/src/backend_scene/standalone_view"
BUILD_DIR="$VIEWER_DIR/build/impl-d10"
VIEWER_BIN="$BUILD_DIR/sceneviewer"
FIXTURE="$REPO_ROOT/tests/fixtures/smoke_scene"
# All run artifacts live UNDER the build tree (never /tmp or ~/.cache — see
# project memory feedback_no_delete_outside).
WORK_DIR="$BUILD_DIR/_render_smoke"
PPM="$WORK_DIR/smoke.ppm"
SPV_CACHE="$WORK_DIR/spv-cache"

# ── args ──────────────────────────────────────────────────────────────────────
DO_BUILD=1
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --keep)     KEEP=1 ;;
        -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "render-smoke: unknown flag: $arg" >&2; exit 1 ;;
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
    # Pick the first lvp_icd.*.json the loader ships.
    LVP_ICD=$(ls /usr/share/vulkan/icd.d/lvp_icd.*.json 2>/dev/null | head -1 || true)
fi
[[ -z "$LVP_ICD" || ! -f "$LVP_ICD" ]] && \
    skip "no lavapipe ICD found (/usr/share/vulkan/icd.d/lvp_icd.*.json) — install Mesa lavapipe to run the render smoke"
ok "lavapipe ICD: $LVP_ICD"

# ── 2. capability probe: WE assets dir ────────────────────────────────────────
# The renderer reads base materials/shaders from the WE assets dir; the fixture
# references models/util/solidlayer.json.  Without it the smoke can't render —
# skip (this is a developer-machine input, not bundled).
step "Probe: Wallpaper Engine assets directory"
ASSETS="${ASSETS_DIR:-}"
if [[ -z "$ASSETS" ]]; then
    for c in \
        "$HOME/.steam/steam/steamapps/common/wallpaper_engine/assets" \
        "$HOME/.local/share/Steam/steamapps/common/wallpaper_engine/assets" \
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/wallpaper_engine/assets"; do
        [[ -d "$c" ]] && { ASSETS="$c"; break; }
    done
fi
[[ -z "$ASSETS" || ! -d "$ASSETS" ]] && \
    skip "Wallpaper Engine assets dir not found (set ASSETS_DIR=... to point at <steamapps>/common/wallpaper_engine/assets)"
ok "assets: $ASSETS"

[[ -f "$FIXTURE/scene.json" ]] || fail "fixture scene missing: $FIXTURE/scene.json"
ok "fixture: $FIXTURE"

# ── 3. capability probe: a windowing display ─────────────────────────────────
# GLFW (even with GLFW_NO_API / pure-Vulkan surface) needs a window system to
# create the swapchain surface.  Prefer xvfb-run (truly headless, CI-safe);
# fall back to an already-present Wayland/X11 display so the smoke is runnable
# in a live desktop session / distrobox today.  The render path is proven on
# BOTH lavapipe-on-Wayland and lavapipe-on-X11.
step "Probe: windowing display (xvfb-run preferred, else live WAYLAND/X11)"
DISPLAY_MODE=""
if command -v xvfb-run >/dev/null 2>&1; then
    DISPLAY_MODE="xvfb"
    ok "xvfb-run present — running truly headless"
elif [[ -n "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}" ]]; then
    DISPLAY_MODE="wayland"
    ok "live Wayland display: $WAYLAND_DISPLAY (no xvfb-run; using existing session)"
elif [[ -n "${DISPLAY:-}" ]]; then
    DISPLAY_MODE="x11"
    ok "live X11 display: $DISPLAY (no xvfb-run; using existing session)"
else
    skip "no display: xvfb-run absent AND no WAYLAND_DISPLAY/DISPLAY (install xorg-x11-server-Xvfb for headless CI)"
fi

# ── 4. build the plain GLFW sceneviewer ───────────────────────────────────────
if [[ "$DO_BUILD" == "1" ]]; then
    step "Build plain sceneviewer (Release, build/impl-d10)"
    SV_GEN=""
    [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]] && SV_GEN=""
    CC="${CC:-clang}" CXX="${CXX:-clang++}" \
        cmake -B "$BUILD_DIR" -S "$VIEWER_DIR" $SV_GEN -DCMAKE_BUILD_TYPE=Release \
        || fail "cmake configure failed"
    cmake --build "$BUILD_DIR" --target sceneviewer -j"$(nproc)" \
        || fail "sceneviewer build failed (check the standalone GLFW viewer compiles)"
    ok "sceneviewer built: $VIEWER_BIN"
fi
[[ -x "$VIEWER_BIN" ]] || fail "sceneviewer binary not found ($VIEWER_BIN) — run without --no-build"

# ── 5. render the fixture headless under lavapipe ─────────────────────────────
mkdir -p "$WORK_DIR" "$SPV_CACHE"
rm -f "$PPM"

# 640x360 avoids the "too small swapchain image size" clamp at <512px while
# keeping the CPU render fast.  --screenshot-frames 20 renders a few frames so
# the (animated) SDF shader has produced content before capture.
RES="640x360"
FRAMES=20

# Build the invocation per display mode.  WAYLAND_DISPLAY is explicitly unset
# for xvfb-run / X11 so GLFW doesn't prefer a (now absent) Wayland socket.
run_viewer() {
    case "$DISPLAY_MODE" in
        xvfb)
            VK_ICD_FILENAMES="$LVP_ICD" \
            xvfb-run -a -s "-screen 0 1280x720x24" \
                env -u WAYLAND_DISPLAY \
                "$VIEWER_BIN" -R "$RES" --screenshot-frames "$FRAMES" \
                    -C "$SPV_CACHE" -S "$PPM" "$ASSETS" "$FIXTURE"
            ;;
        wayland)
            VK_ICD_FILENAMES="$LVP_ICD" \
                "$VIEWER_BIN" -R "$RES" --screenshot-frames "$FRAMES" \
                    -C "$SPV_CACHE" -S "$PPM" "$ASSETS" "$FIXTURE"
            ;;
        x11)
            VK_ICD_FILENAMES="$LVP_ICD" \
                env -u WAYLAND_DISPLAY \
                "$VIEWER_BIN" -R "$RES" --screenshot-frames "$FRAMES" \
                    -C "$SPV_CACHE" -S "$PPM" "$ASSETS" "$FIXTURE"
            ;;
    esac
}

step "Render fixture under lavapipe ($DISPLAY_MODE, $RES, $FRAMES frames)"
echo "  device should report llvmpipe (lavapipe = the LLVM-backed Mesa CPU device)"
rc=0
run_viewer || rc=$?
if [[ "$rc" -ne 0 ]]; then
    fail "sceneviewer exited rc=$rc (render path crashed / failed to create device or window)"
fi
ok "sceneviewer exited rc=0"

# ── 6. assert: PPM exists, parses, and is NON-BLANK ───────────────────────────
step "Assert: framebuffer is non-blank"
[[ -s "$PPM" ]] || fail "no PPM written (expected $PPM)"

# Parse the binary P6 PPM and check for real image content: more than one
# distinct colour AND a nonzero summed per-channel range.  A solid clear /
# black / empty frame fails.  (No ImageMagick dependency — parse directly.)
python3 - "$PPM" <<'PY' || fail "framebuffer BLANK or unparseable (render produced no visible content)"
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
if data[:2] != b"P6":
    print("not a P6 PPM"); sys.exit(1)

# Read three whitespace-delimited ASCII tokens (width, height, maxval) after
# the magic, then a single whitespace byte, then raw RGB triples.
i = 2
def read_token(i):
    while i < len(data) and data[i:i+1].isspace():
        i += 1
    s = i
    while i < len(data) and not data[i:i+1].isspace():
        i += 1
    return data[s:i], i
wtok, i = read_token(i)
htok, i = read_token(i)
mtok, i = read_token(i)
i += 1  # the single whitespace separating header from pixel data
w, h, mx = int(wtok), int(htok), int(mtok)
pix = data[i:]
n = len(pix) // 3
if n == 0 or len(pix) < w * h * 3:
    print(f"truncated PPM: {w}x{h} maxval={mx} got {len(pix)} bytes, need {w*h*3}")
    sys.exit(1)

colors = set()
mins = [255, 255, 255]
maxs = [0, 0, 0]
sums = [0, 0, 0]
for p in range(0, n * 3, 3):
    r, g, b = pix[p], pix[p+1], pix[p+2]
    colors.add((r, g, b))
    for c, v in ((0, r), (1, g), (2, b)):
        sums[c] += v
        if v < mins[c]: mins[c] = v
        if v > maxs[c]: maxs[c] = v
means = [round(s / n, 1) for s in sums]
range_sum = sum(maxs[c] - mins[c] for c in range(3))
print(f"  {w}x{h}  distinct_colors={len(colors)}  mean={means}  "
      f"min={mins}  max={maxs}  range_sum={range_sum}")

# Non-blank oracle: must have >1 distinct colour AND a meaningful spread.
# range_sum > 3 rejects a single flat fill (incl. a pure clear colour); the
# fixture's SDF shader produces hundreds of colours and a wide range.
if len(colors) <= 1 or range_sum <= 3:
    print("  -> BLANK")
    sys.exit(1)
print("  -> NON-BLANK")
sys.exit(0)
PY
ok "framebuffer non-blank — render path executed end-to-end (device + render-graph + SPIR-V + passes + swapchain readback)"

# ── 7. cleanup (keep on --keep) ───────────────────────────────────────────────
if [[ "$KEEP" == "1" ]]; then
    warn "kept capture: $PPM"
else
    rm -f "$PPM"
fi

printf '\n%sRender smoke PASSED.%s\n' "$GREEN" "$RESET"
# NOTE: D10b (deterministic framebuffer-hash assertion) is DEFERRED — it needs
# the frame-indexed capture trigger from spec item D11 (P1.2). The current
# wall-clock capture varies run-to-run, so only the structural non-blank oracle
# above is asserted here.
exit 0
