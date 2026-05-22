#!/usr/bin/env bash
# Pre-push verification: lint -> submodule build/tests -> main tests -> fuzz smoke.
#
# Usage:
#   scripts/preflight.sh              # lint + build + tests + fuzz smoke
#   scripts/preflight.sh --fix        # auto-format then build + tests + fuzz
#   scripts/preflight.sh --lint-only  # just clang-format check (fast)
#   scripts/preflight.sh --no-build   # skip cmake builds, run existing tests only
#   scripts/preflight.sh --no-fuzz    # skip fuzz smoke (lint + tests still run)
#   scripts/preflight.sh --bootstrap  # (re-)provision fedora distrobox + deps and exit
#   scripts/preflight.sh --tsan       # opt-in TSAN leg: WEK_SANITIZE=thread, runs
#                                      #   scenescript_tests + backend_scene_thread_tests
#   scripts/preflight.sh --sanitize=address,undefined  # opt-in ASAN+UBSAN leg over the
#                                      #   parent + submodule suites (currently NON-FATAL —
#                                      #   surfaces findings, does not fail the run)
#   scripts/preflight.sh --werror     # opt-in -Werror leg: configures the full project
#                                      #   with -DWEK_WERROR=ON and builds the shippable
#                                      #   targets. NON-FATAL today (surfaces residual
#                                      #   warnings); flip WERROR_FATAL=1 once the tree is
#                                      #   warning-clean to make it a gate.
#   scripts/preflight.sh --render-smoke # opt-in headless render smoke (D10a): builds the
#                                      #   plain GLFW sceneviewer, renders a tiny fixture
#                                      #   under Mesa lavapipe (CPU Vulkan, no GPU), asserts
#                                      #   rc==0 + non-blank framebuffer. SKIPS cleanly when
#                                      #   lavapipe / a display / WE assets are absent.
#                                      #   NOT in the default gate (lavapipe CPU runs slow).
#   scripts/preflight.sh --render-oracle # opt-in headless render self-comparison: motion
#                                      #   (frame@early != frame@late) + warm==cold (byte-
#                                      #   identical across a cold->warm SPV-cache run) on the
#                                      #   fantasticcar default. SKIPS when assets absent.
#                                      #   NOT in the default gate (lavapipe CPU runs slow).
#
# The --tsan / --sanitize / --werror / --render-smoke / --render-oracle legs are
# standalone (lint + that one build/run only); they use fresh build dirs
# (build/impl-tsan / build/impl-asan / build/impl-werror / build/impl-d10 /
# build/impl-oracle) and do not run the normal build/test/fuzz flow.
#
# Env: FUZZ_SECS=N overrides per-target fuzz duration (default 20; 7 targets ≈ 2.3 min).
#
# Auto-runs on `git push` if hooks are installed:
#   git config core.hooksPath scripts/git-hooks   # enable
#   git push --no-verify                          # skip once
#   git config --unset core.hooksPath             # disable
#
# Distrobox bootstrap:
#   On the first run (or with --bootstrap) preflight will create the fedora
#   distrobox if missing and install every dependency listed in DEPS_FEDORA
#   below. The list mirrors the README, the RPM/Deb specs, the CI workflows,
#   plus libasan/libubsan/vulkan-validation-layers/vulkan-tools/gdb for
#   sanitizer + Vulkan-debug builds (not yet wired into CI but documented).

set -euo pipefail

# Resolve to the parent repo's working tree even when invoked from inside the
# `src/backend_scene` submodule.  Plain --show-toplevel would land us in the
# submodule, which silently swaps `git ls-files` (lint scope) and `cmake -B
# build/sub -S src/backend_scene` (path doubling) — that wedge once mass-
# reformatted third_party/ headers and tried to build src/backend_scene/src/
# backend_scene.  --show-superproject-working-tree is empty in the parent and
# the submodule path when called from inside the submodule, so we prefer it.
_SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
cd "${_SUPER:-$(git rev-parse --show-toplevel)}"

# ── Args ──────────────────────────────────────────────────────────────────────
MODE=full
NO_FUZZ=0
SAN_SPEC=""
for arg in "$@"; do
    case "$arg" in
        --lint-only) MODE=lint ;;
        --fix)       MODE=fix ;;
        --no-build)  MODE=test-only ;;
        --no-fuzz)   NO_FUZZ=1 ;;
        --bootstrap) MODE=bootstrap ;;
        --tsan)      MODE=sanitize; SAN_SPEC="thread" ;;
        --sanitize=*) MODE=sanitize; SAN_SPEC="${arg#--sanitize=}" ;;
        --werror)    MODE=werror ;;
        --render-smoke) MODE=render-smoke ;;
        --render-oracle) MODE=render-oracle ;;
        -h|--help)
            sed -n '2,44p' "$0"
            exit 0
            ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
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
warn() { printf '%s  warn%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '\n%sFAIL:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ── Fedora dependency manifest ───────────────────────────────────────────────
# Single source of truth for packages required to build, test, and debug the
# project on a fresh fedora-toolbox. Mirrors README + rpm/wek.spec +
# debian/control + .github/workflows/ci.yml, with extras for ASAN runs and
# Vulkan validation that are documented in CLAUDE.md but not yet in CI.
CONTAINER_NAME="fedora"
CONTAINER_IMAGE="registry.fedoraproject.org/fedora-toolbox:latest"
DEPS_FEDORA=(
    # core toolchain
    clang cmake extra-cmake-modules ninja-build pkgconf-pkg-config git nodejs gdb

    # Vulkan (headers + loader devel for cmake's FindVulkan, validation + tools for debug)
    vulkan-headers vulkan-loader-devel vulkan-validation-layers vulkan-tools

    # KDE Plasma 6 / KF6
    plasma-workspace plasma-workspace-devel libplasma-devel
    kf6-kcoreaddons-devel kf6-kpackage-devel kf6-kirigami-devel kf6-kcmutils

    # Qt 6
    qt6-qtbase-devel qt6-qtbase-private-devel
    qt6-qtdeclarative-devel qt6-qtwebchannel-devel qt6-qtwebsockets-devel

    # native libs
    lz4-devel mpv-devel freetype-devel glfw-devel

    # sanitizer runtimes (libasan.so.8 lives only inside distrobox per CLAUDE.md)
    libasan libubsan
)

# ── Distrobox detection + bootstrap ──────────────────────────────────────────
# Returns true when we are already inside a usable Fedora build context, so the
# script runs the gates DIRECTLY instead of trying to `distrobox create`.
#
# Two ways to qualify:
#   1. CI short-circuit: WEK_IN_CI=1 (explicit) or the standard CI=true that CI
#      runners export.  A stock `fedora:latest` container is plain podman/docker
#      with a different (or absent) name= in /run/.containerenv, so the distrobox
#      name probe below would miss it and wrongly attempt a distrobox-create that
#      cannot work inside a container.  The env gate lets preflight run as the
#      comprehensive gate inside ANY Fedora context (CI image, plain container).
#   2. The real distrobox probe: /run/.containerenv carries name="fedora".
# The superproject-CWD guard above still holds — this only changes whether we
# wrap commands in `distrobox enter`, not where we run them.
inside_fedora() {
    [[ "${WEK_IN_CI:-}" == "1" || "${CI:-}" == "true" || "${CI:-}" == "1" ]] && return 0
    [[ -f /run/.containerenv ]] && grep -q 'name="fedora"' /run/.containerenv 2>/dev/null
}

container_exists() {
    # Capture first, then grep the string. Piping `distrobox list` into
    # `grep -q` makes grep close the pipe as soon as it matches; the writer
    # then takes SIGPIPE (exit 141) and `set -o pipefail` reports that as the
    # pipeline status — so this check spuriously failed and the dep bootstrap
    # ran on every host invocation.
    local list
    list=$(distrobox list 2>/dev/null || true)
    grep -qE "^\S+\s*\|\s*${CONTAINER_NAME}\s" <<<"$list"
}

bootstrap_fedora() {
    step "Bootstrap: fedora distrobox + dependencies"

    # In-container bootstrap: just refresh deps via dnf directly.
    if inside_fedora; then
        warn "running inside fedora distrobox — installing/refreshing deps in place"
        sudo dnf install -y "${DEPS_FEDORA[@]}" \
            || fail "dnf install failed"
        ok "${#DEPS_FEDORA[@]} packages installed"
        return
    fi

    if ! command -v distrobox >/dev/null; then
        fail "distrobox not found on host (needed for builds; install distrobox or re-run from inside the fedora distrobox)"
    fi

    if container_exists; then
        ok "fedora distrobox already exists"
    else
        warn "fedora distrobox missing — creating from ${CONTAINER_IMAGE} (this may take a few minutes)"
        distrobox create --yes -i "$CONTAINER_IMAGE" -n "$CONTAINER_NAME" \
            || fail "distrobox create failed"
        ok "container created"
    fi

    step "Installing fedora deps (${#DEPS_FEDORA[@]} packages — first run can take several minutes)"
    distrobox enter "$CONTAINER_NAME" -- bash -lc "sudo dnf install -y ${DEPS_FEDORA[*]}" \
        || fail "dnf install inside container failed"
    ok "dependencies installed"
}

# ── Distrobox wrapper ────────────────────────────────────────────────────────
# Builds need Fedora dev packages. If we're already inside the fedora
# distrobox, run commands directly; otherwise wrap them in `distrobox enter`.
# Auto-bootstrap when the container is missing so `preflight.sh` works on a
# fresh checkout without manual setup.
if inside_fedora; then
    DBOX_PREFIX=()
    [[ "$MODE" == "bootstrap" ]] && bootstrap_fedora
    ok "running inside fedora distrobox"
else
    if [[ "$MODE" == "bootstrap" ]] || ! container_exists; then
        bootstrap_fedora
    fi
    DBOX_PREFIX=(distrobox enter "$CONTAINER_NAME" --)
fi
dbox() { "${DBOX_PREFIX[@]}" bash -lc "$*"; }

# Bootstrap-only mode: don't run lint/build/tests.
if [[ "$MODE" == "bootstrap" ]]; then
    printf '\n%sBootstrap complete — re-run without --bootstrap to lint/build/test.%s\n' "$GREEN" "$RESET"
    exit 0
fi

# ── Sanitizer legs (opt-in, standalone) ───────────────────────────────────────
# --tsan                    => WEK_SANITIZE=thread  (FATAL on a race)
# --sanitize=address,undefined (etc) => ASAN/UBSAN  (NON-FATAL: surfaces findings)
# Both use fresh build dirs and skip the normal lint/build/test/fuzz flow.
if [[ "$MODE" == "sanitize" ]]; then
    REPO_ROOT="$(pwd)"
    case "$SAN_SPEC" in
        thread)
            step "TSAN leg (WEK_SANITIZE=thread)"
            # Build the Qt SceneScript suite + the focused thread repro under TSAN.
            # backend_scene_thread_tests links wpScene (no Vulkan) and drives the
            # real B5(b) parent-tree fix + a generic atomic<shared_ptr> repro (B5a).
            dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
                  cmake -B build/impl-tsan -S src/backend_scene -G Ninja \
                        -DBUILD_TESTS=ON -DWEK_SANITIZE=thread \
                        -DCMAKE_BUILD_TYPE=Debug \
                  && cmake --build build/impl-tsan \
                        --target scenescript_tests backend_scene_thread_tests" \
                || fail "TSAN build failed"
            ok "TSAN targets built"

            # halt_on_error=1 + a non-zero exitcode make any race fail the leg.
            # Suppress only known-benign Qt/glib/libstdc++ runtime internals.
            local_tsan_opts="suppressions=${REPO_ROOT}/tsan.supp:halt_on_error=1:exitcode=66"

            step "Run backend_scene_thread_tests under TSAN"
            dbox "TSAN_OPTIONS='${local_tsan_opts}' \
                  QT_QPA_PLATFORM=offscreen \
                  ./build/impl-tsan/src/Test/backend_scene_thread_tests" \
                || fail "backend_scene_thread_tests reported a TSAN race (or crashed)"
            ok "backend_scene_thread_tests: TSAN clean"

            step "Run scenescript_tests under TSAN"
            dbox "TSAN_OPTIONS='${local_tsan_opts}' \
                  QT_QPA_PLATFORM=offscreen \
                  ./build/impl-tsan/src/Test/scenescript_tests" \
                || fail "scenescript_tests reported a TSAN race (or a test failed)"
            ok "scenescript_tests: TSAN clean"

            printf '\n%sTSAN leg passed — no races detected.%s\n' "$GREEN" "$RESET"
            exit 0
            ;;
        *)
            # ASAN/UBSAN (and any address/undefined combo).  NON-FATAL: this leg
            # surfaces findings to the log but does not fail preflight yet (the
            # suites have not been audited clean under sanitizers).  Build with
            # BUILD_FUZZERS=OFF so the fuzzers' own -fsanitize=fuzzer,... flags
            # don't double-instrument.
            step "Sanitizer leg (WEK_SANITIZE=${SAN_SPEC}) — NON-FATAL (surfaces findings)"

            # Submodule suites.
            dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
                  cmake -B build/impl-asan -S src/backend_scene -G Ninja \
                        -DBUILD_TESTS=ON -DBUILD_FUZZERS=OFF \
                        -DWEK_SANITIZE=${SAN_SPEC} \
                        -DCMAKE_BUILD_TYPE=Debug \
                  && cmake --build build/impl-asan \
                        --target backend_scene_tests scenescript_tests" \
                || warn "submodule sanitizer build had errors (see log)"

            # detect_leaks=0: the parsers intentionally retain some long-lived
            # state in these short-lived test runs; LSAN noise would drown the
            # heap/UB findings we care about.  halt_on_error=0 + recover so the
            # full suite runs and ALL findings print (leg is non-fatal anyway).
            asan_opts="detect_leaks=0:halt_on_error=0:print_stacktrace=1"
            ubsan_opts="halt_on_error=0:print_stacktrace=1"

            step "Run backend_scene_tests under ${SAN_SPEC} (non-fatal)"
            # WEKDE_HAS_AUDIO_DEVICE intentionally unset (avoids the device-enum hang).
            dbox "ASAN_OPTIONS='${asan_opts}' UBSAN_OPTIONS='${ubsan_opts}' \
                  ./build/impl-asan/src/Test/backend_scene_tests" \
                || warn "backend_scene_tests surfaced sanitizer findings (non-fatal — see log)"

            step "Run scenescript_tests under ${SAN_SPEC} (non-fatal)"
            dbox "ASAN_OPTIONS='${asan_opts}' UBSAN_OPTIONS='${ubsan_opts}' \
                  QT_QPA_PLATFORM=offscreen \
                  ./build/impl-asan/src/Test/scenescript_tests" \
                || warn "scenescript_tests surfaced sanitizer findings (non-fatal — see log)"

            # Parent project suites (FileHelper, mpvbackend, etc.).
            step "Build + run parent tests under ${SAN_SPEC} (non-fatal)"
            dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
                  cmake -B build/impl-asan-main -S tests -G Ninja \
                        -DWEK_SANITIZE=${SAN_SPEC} \
                        -DCMAKE_BUILD_TYPE=Debug \
                  && cmake --build build/impl-asan-main" \
                || warn "parent-tests sanitizer build had errors (see log)"
            dbox "ASAN_OPTIONS='${asan_opts}' UBSAN_OPTIONS='${ubsan_opts}' \
                  QT_QPA_PLATFORM=offscreen \
                  ctest --test-dir build/impl-asan-main --output-on-failure" \
                || warn "parent ctest surfaced sanitizer findings (non-fatal — see log)"

            printf '\n%sSanitizer leg complete (NON-FATAL) — review the log above for findings.%s\n' "$YELLOW" "$RESET"
            exit 0
            ;;
    esac
fi

# ── -Werror leg (opt-in, standalone) ──────────────────────────────────────────
# Configures the FULL project with -DWEK_WERROR=ON and builds it.  WEK_WERROR
# appends -Werror to the first-party warn lists ONLY (third_party + Qt MOC keep
# their own flags by construction), and keeps the -Wconversion/-Wsign-conversion
# family WARNING-only.  Fresh build dir build/impl-werror; skips lint/test/fuzz.
#
# NON-FATAL by default: the shippable targets (plugin .so, backend_mpv, the QML
# bridge, wpParticle) are -Wall -Wextra clean, but the wider renderer libs have
# not yet been audited under -Werror, so a residual -Wall/-Wextra warning there
# would fail the build.  Until the whole tree is clean this leg surfaces the
# breakage without failing preflight.  Flip it to a gate with WERROR_FATAL=1
# (and then wire it into the default flow / pre-push hook).
if [[ "$MODE" == "werror" ]]; then
    step "-Werror leg (WEK_WERROR=ON) — ${YELLOW}NON-FATAL${RESET} unless WERROR_FATAL=1"
    WERR_GEN=""
    [[ ! -f build/impl-werror/CMakeCache.txt ]] && WERR_GEN="-G Ninja"
    if dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
             cmake -B build/impl-werror -S . $WERR_GEN \
                   -DWEK_WERROR=ON -DCMAKE_BUILD_TYPE=Debug \
             && cmake --build build/impl-werror"; then
        ok "-Werror build clean (first-party targets warning-free under -Wall -Wextra)"
        printf '\n%sWEK_WERROR leg passed.%s\n' "$GREEN" "$RESET"
        exit 0
    else
        if [[ "${WERROR_FATAL:-0}" == "1" ]]; then
            fail "-Werror build failed (WERROR_FATAL=1) — a first-party -Wall/-Wextra warning is now an error"
        fi
        warn "-Werror build had warnings-as-errors (non-fatal — see log; set WERROR_FATAL=1 to gate)"
        printf '\n%s-Werror leg complete (NON-FATAL) — residual first-party warnings above.%s\n' "$YELLOW" "$RESET"
        exit 0
    fi
fi

# ── Render-smoke leg (opt-in, standalone) — D10a ──────────────────────────────
# Builds the plain GLFW sceneviewer and renders a tiny fixture scene headless
# under Mesa lavapipe (CPU Vulkan), asserting rc==0 + a NON-BLANK framebuffer.
# This is the ONLY gate that actually runs the product (Vulkan device creation,
# render-graph build, SPIR-V compile, pass execution, swapchain readback) on a
# machine with no GPU — it catches the "renders all-black / device-init crash"
# regression class that the Vulkan-free unit tests structurally cannot.
#
# DELIBERATELY opt-in (not in the default flow): a CPU-Vulkan render is slow.
# The driver (scripts/render-smoke.sh) self-probes lavapipe + a display
# (xvfb-run preferred, else a live Wayland/X11 session) + the WE assets dir, and
# exits 77 to mean "capability missing — SKIP" so this leg is graceful on a box
# without lavapipe/Xvfb (mirrors the existing skip patterns).
#
# NOTE: the deterministic framebuffer-HASH form (D10b) is deferred — it needs
# the frame-indexed capture trigger from D11 (P1.2); the current wall-clock
# capture varies run-to-run, so only the structural non-blank oracle runs here.
if [[ "$MODE" == "render-smoke" ]]; then
    step "Render smoke (D10a — headless Vulkan via lavapipe)"
    rc=0
    dbox "scripts/render-smoke.sh" || rc=$?
    case "$rc" in
        0)  ok "render smoke passed (rc==0, framebuffer non-blank)"
            printf '\n%sRender-smoke leg passed.%s\n' "$GREEN" "$RESET"
            ;;
        77) ok "render smoke skipped (no lavapipe / display / WE assets — see log)"
            printf '\n%sRender-smoke leg skipped (capability missing).%s\n' "$YELLOW" "$RESET"
            ;;
        *)  fail "render smoke failed (rc=$rc) — render path crashed or framebuffer was BLANK"
            ;;
    esac
    exit 0
fi

# ── opt-in: headless render ORACLE (self-comparison) ──────────────────────────
# Deeper than --render-smoke: renders the fantasticcar bundled default in
# deterministic mode and asserts MOTION (frame@early != frame@late) and
# WARM==COLD (byte-identical capture across a cold->warm SPV-cache run).  Catches
# the "skip work on a cached/warm/per-frame path" regression class (RC2 freeze,
# LD2-B texture-clear) that green headless unit tests cannot.  Opt-in, not in the
# default gate (CPU-Vulkan rendering is slow); self-probes + exits 77 to SKIP
# when lavapipe / display / WE assets / the fantasticcar fixture are absent.
if [[ "$MODE" == "render-oracle" ]]; then
    step "Render oracle (self-comparison — headless Vulkan via lavapipe)"
    rc=0
    dbox "scripts/render-oracle.sh" || rc=$?
    case "$rc" in
        0)  ok "render oracle passed (motion + warm==cold)"
            printf '\n%sRender-oracle leg passed.%s\n' "$GREEN" "$RESET"
            ;;
        77) ok "render oracle skipped (no lavapipe / display / WE assets / fixture — see log)"
            printf '\n%sRender-oracle leg skipped (capability missing).%s\n' "$YELLOW" "$RESET"
            ;;
        *)  fail "render oracle failed (rc=$rc) — motion or warm==cold assertion failed"
            ;;
    esac
    exit 0
fi

# ── 1. Lint: clang-format ─────────────────────────────────────────────────────
step "Lint (clang-format)"
# Route clang-format through the distrobox (DBOX_PREFIX) exactly like the builds
# below, so the container's clang-format is used whether preflight runs from the
# host or from inside the box. Keeps formatting deterministic and removes the
# dependency on a host clang-format being installed (or matching the box's
# version). DBOX_PREFIX is empty inside the box, so this is a no-op there.
if ! dbox "command -v clang-format >/dev/null"; then
    fail "clang-format not found in the fedora distrobox (run: scripts/preflight.sh --bootstrap)"
fi

# Parent-repo C/C++ files only. git ls-files does not recurse into submodules,
# so src/backend_scene/ is excluded automatically (it has its own conventions).
mapfile -t SRCS < <(git ls-files '*.cpp' '*.cc' '*.cxx' '*.c' '*.h' '*.hpp' '*.hxx' \
    | grep -vE '^(build|tests/build|tests/fixtures)/' || true)

if [[ ${#SRCS[@]} -eq 0 ]]; then
    warn "no C/C++ files found"
else
    case "$MODE" in
        fix)
            # `clang-format --dry-run --Werror` exits non-zero on violations.
            # With set -euo pipefail that kills the substitution before -i
            # ever runs, so explicitly swallow the pipeline status.
            BEFORE_HASH=$("${DBOX_PREFIX[@]}" clang-format --dry-run --Werror "${SRCS[@]}" 2>&1 | wc -l || true)
            "${DBOX_PREFIX[@]}" clang-format -i "${SRCS[@]}"
            if [[ "$BEFORE_HASH" -gt 0 ]]; then
                CHANGED=$(git diff --name-only -- "${SRCS[@]}" | wc -l)
                ok "auto-formatted ${CHANGED} files (review with 'git diff' before committing)"
            else
                ok "clang-format clean (${#SRCS[@]} files, no changes needed)"
            fi
            ;;
        *)
            if ! "${DBOX_PREFIX[@]}" clang-format --dry-run --Werror "${SRCS[@]}" 2>&1; then
                fail "clang-format violations — run 'scripts/preflight.sh --fix' to auto-format"
            fi
            ok "clang-format clean (${#SRCS[@]} files)"
            ;;
    esac
fi

[[ "$MODE" == "lint" ]] && { printf '\n%sLint passed.%s\n' "$GREEN" "$RESET"; exit 0; }

# ── 2. Build submodule (with tests) ───────────────────────────────────────────
# Only force -G Ninja on fresh dirs; otherwise reuse the existing generator so
# we don't fight with manual build dirs the user already configured.
if [[ "$MODE" != "test-only" ]]; then
    step "Build submodule (src/backend_scene, BUILD_TESTS=ON)"
    SUB_GEN=""
    [[ ! -f build/sub/CMakeCache.txt ]] && SUB_GEN="-G Ninja"
    # BUILD_FUZZERS=ON adds the fuzz_* targets without compiling them — section
    # 6 builds them on demand. Configuring once here keeps the cache consistent.
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B build/sub -S src/backend_scene $SUB_GEN \
                -DBUILD_TESTS=ON -DBUILD_TOOLS=ON -DBUILD_FUZZERS=ON \
                -DCMAKE_BUILD_TYPE=Debug \
          && cmake --build build/sub" \
        || fail "submodule build failed"
    ok "submodule built"
fi

# ── 3. Run submodule tests ────────────────────────────────────────────────────
step "Submodule tests"
[[ -x build/sub/src/Test/backend_scene_tests ]] \
    || fail "build/sub/src/Test/backend_scene_tests not built (run without --no-build)"
dbox "./build/sub/src/Test/backend_scene_tests" || fail "backend_scene_tests failed"
ok "backend_scene_tests passed"
dbox "./build/sub/src/Test/scenescript_tests"   || fail "scenescript_tests failed"
ok "scenescript_tests passed"

# ── 4. Build main project tests ───────────────────────────────────────────────
if [[ "$MODE" != "test-only" ]]; then
    step "Build main project tests (tests/)"
    TEST_GEN=""
    [[ ! -f build/tests/CMakeCache.txt ]] && TEST_GEN="-G Ninja"
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B build/tests -S tests $TEST_GEN \
                -DCMAKE_BUILD_TYPE=Debug \
          && cmake --build build/tests" \
        || fail "tests build failed"
    ok "tests built"
fi

# ── 5. Run main tests via ctest ───────────────────────────────────────────────
step "Main project tests (ctest)"
dbox "ctest --test-dir build/tests --output-on-failure" || fail "ctest failed"
ok "ctest passed"

# ── 6. Fuzz smoke (libFuzzer cold-start regression gate) ─────────────────────
# Catches the unbounded-resize / unterminated-buffer bug class on parser entry
# points (WPMdlParser, WPTexImageParser). Cold-start only: no seed corpus
# dependency, so this works on a fresh checkout. Each harness ~30s; 60s total.
# Findings (crash/oom/timeout/leak) under build/sub/fuzz-crashes/ fail the gate.
if [[ "$NO_FUZZ" == "0" ]]; then
    FUZZ_SECS="${FUZZ_SECS:-20}"
    FUZZ_TARGETS=(WPMdlParser WPTexImageParser WPPkgFs
                  WPShaderParser WPShaderCompile WPSceneParser
                  WPParticleParser WPSoundParser)
    step "Fuzz smoke (libFuzzer cold-start, ${FUZZ_SECS}s × ${#FUZZ_TARGETS[@]} targets)"

    if [[ "$MODE" != "test-only" ]]; then
        dbox "cmake --build build/sub --target fuzzers" \
            || fail "fuzzer build failed"
    fi

    crash_dir=build/sub/fuzz-crashes
    rm -rf "$crash_dir" && mkdir -p "$crash_dir"

    for target in "${FUZZ_TARGETS[@]}"; do
        binary="build/sub/src/Test/fuzz_$target"
        if [[ ! -x "$binary" ]]; then
            warn "fuzz_$target not built — skipping"
            continue
        fi
        corpus="build/sub/fuzz-corpus-$target"
        mkdir -p "$corpus"
        # libFuzzer exits non-zero on first finding (which is what we want for a
        # gate). set -o pipefail inside dbox preserves that exit through tail.
        dbox "set -o pipefail; $binary $corpus \
                -max_total_time=$FUZZ_SECS -timeout=5 -max_len=65536 \
                -malloc_limit_mb=512 -rss_limit_mb=2048 \
                -artifact_prefix=$crash_dir/ -print_final_stats=1 2>&1 \
              | tail -8" || true
        artifacts=$(find "$crash_dir" -maxdepth 1 -type f \
            \( -name 'crash-*' -o -name 'oom-*' \
               -o -name 'timeout-*' -o -name 'leak-*' \) 2>/dev/null | wc -l)
        if [[ "$artifacts" -gt 0 ]]; then
            echo
            echo "Findings in $crash_dir:"
            find "$crash_dir" -maxdepth 1 -type f \
                \( -name 'crash-*' -o -name 'oom-*' \
                   -o -name 'timeout-*' -o -name 'leak-*' \) \
                -printf '  %f\n' | sort
            fail "fuzz_$target found $artifacts new finding(s) — replay with: $binary $crash_dir/<artifact>"
        fi
        ok "fuzz_$target: ${FUZZ_SECS}s clean"
    done
fi

printf '\n%sAll preflight checks passed — safe to push.%s\n' "$GREEN" "$RESET"
