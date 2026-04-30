#!/usr/bin/env bash
# Pre-push verification: lint -> submodule build/tests -> main tests.
#
# Usage:
#   scripts/preflight.sh              # lint check + build + tests (fail on violations)
#   scripts/preflight.sh --fix        # auto-format then build + tests (one-shot for push)
#   scripts/preflight.sh --lint-only  # just clang-format check (fast)
#   scripts/preflight.sh --no-build   # skip cmake builds, run existing tests only
#
# Auto-runs on `git push` if hooks are installed:
#   git config core.hooksPath scripts/git-hooks   # enable
#   git push --no-verify                          # skip once
#   git config --unset core.hooksPath             # disable

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ── Args ──────────────────────────────────────────────────────────────────────
MODE=full
for arg in "$@"; do
    case "$arg" in
        --lint-only) MODE=lint ;;
        --fix)       MODE=fix ;;
        --no-build)  MODE=test-only ;;
        -h|--help)
            sed -n '2,15p' "$0"
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

# ── Distrobox wrapper ────────────────────────────────────────────────────────
# Builds need Fedora dev packages that live inside the `fedora` distrobox.
# Auto-detect: if we're already inside it, run commands directly.
if [[ -f /run/.containerenv ]] && grep -q 'name="fedora"' /run/.containerenv 2>/dev/null; then
    DBOX_PREFIX=()
    ok "running inside fedora distrobox"
else
    if ! command -v distrobox >/dev/null; then
        fail "distrobox not found on host (needed for builds; install or run inside fedora distrobox)"
    fi
    if ! distrobox list 2>/dev/null | grep -qE '^\S+\s*\|\s*fedora\s'; then
        fail "fedora distrobox not found (create with: distrobox create -i registry.fedoraproject.org/fedora-toolbox:latest -n fedora)"
    fi
    DBOX_PREFIX=(distrobox enter fedora --)
fi
dbox() { "${DBOX_PREFIX[@]}" bash -lc "$*"; }

# ── 1. Lint: clang-format ─────────────────────────────────────────────────────
step "Lint (clang-format)"
if ! command -v clang-format >/dev/null; then
    fail "clang-format not found (install clang-tools-extra or clang)"
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
            BEFORE_HASH=$(clang-format --dry-run --Werror "${SRCS[@]}" 2>&1 | wc -l)
            clang-format -i "${SRCS[@]}"
            if [[ "$BEFORE_HASH" -gt 0 ]]; then
                CHANGED=$(git diff --name-only -- "${SRCS[@]}" | wc -l)
                ok "auto-formatted ${CHANGED} files (review with 'git diff' before committing)"
            else
                ok "clang-format clean (${#SRCS[@]} files, no changes needed)"
            fi
            ;;
        *)
            if ! clang-format --dry-run --Werror "${SRCS[@]}" 2>&1; then
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
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B build/sub -S src/backend_scene $SUB_GEN \
                -DBUILD_TESTS=ON -DBUILD_TOOLS=ON -DCMAKE_BUILD_TYPE=Debug \
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

printf '\n%sAll preflight checks passed — safe to push.%s\n' "$GREEN" "$RESET"
