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
for arg in "$@"; do
    case "$arg" in
        --lint-only) MODE=lint ;;
        --fix)       MODE=fix ;;
        --no-build)  MODE=test-only ;;
        --no-fuzz)   NO_FUZZ=1 ;;
        --bootstrap) MODE=bootstrap ;;
        -h|--help)
            sed -n '2,24p' "$0"
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
inside_fedora() {
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
                  WPShaderParser WPSceneParser WPParticleParser WPSoundParser)
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
