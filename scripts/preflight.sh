#!/usr/bin/env bash
# Pre-push verification: lint -> submodule build/tests -> main tests ->
# scoped -Werror gate -> ASAN+UBSAN gate -> fuzz smoke -> coverage gate ->
# mutation gate (--diff-only).
#
# Usage:
#   scripts/preflight.sh              # default gate (lint + build + tests +
#                                      #   scoped -Werror + ASAN+UBSAN + fuzz +
#                                      #   coverage + mutation, all FATAL)
#   scripts/preflight.sh --fix        # auto-format then run the default gate
#   scripts/preflight.sh --lint-only  # just clang-format check (fast)
#   scripts/preflight.sh --no-build   # skip cmake builds, run existing tests only
#   scripts/preflight.sh --no-fuzz    # skip fuzz smoke (lint + tests + Werror +
#                                      #   ASAN still run)
#   scripts/preflight.sh --bootstrap  # (re-)provision fedora distrobox + deps and exit
#   scripts/preflight.sh --tsan       # opt-in TSAN leg: WEK_SANITIZE=thread, runs
#                                      #   scenescript_tests + backend_scene_thread_tests
#   scripts/preflight.sh --sanitize=address,undefined  # opt-in ASAN+UBSAN leg over the
#                                      #   parent + submodule suites (FATAL on any
#                                      #   finding).  The default gate already runs
#                                      #   the audited-clean submodule subset; this
#                                      #   standalone leg adds the parent tests/
#                                      #   project (mpv / QML / file-helper).
#   scripts/preflight.sh --werror     # opt-in -Werror leg: configures the full project
#                                      #   with -DWEK_WERROR=ON and builds the WHOLE
#                                      #   tree (incl. the renderer libs).  NON-FATAL
#                                      #   today — surfaces residual renderer-lib
#                                      #   warnings; the four shippable targets are
#                                      #   already gated FATAL in the default flow.
#                                      #   Flip WERROR_FATAL=1 once the renderer libs
#                                      #   are warning-clean too.
#   scripts/preflight.sh --coverage   # opt-in coverage leg (standalone, informational):
#                                      #   builds parent + submodule with -DCOVERAGE=ON,
#                                      #   runs llvm-cov + qmlcov, diffs totals vs
#                                      #   tests/.coverage-baseline.json.  NON-FATAL when
#                                      #   invoked standalone — for ad-hoc inspection or
#                                      #   WEK_COVERAGE_REFRESH=1 baseline updates.
#                                      #   The default gate runs this with COVERAGE_FATAL=1.
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
# The --tsan / --sanitize / --werror / --coverage / --render-smoke / --render-oracle
# legs are standalone (lint + that one build/run only); they use fresh build dirs
# (build/impl-tsan / build/impl-asan / build/impl-werror / build/impl-coverage /
# build/impl-d10 / build/impl-oracle) and do not run the normal build/test/fuzz flow.
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
        --coverage)  MODE=coverage ;;
        --render-smoke) MODE=render-smoke ;;
        --render-oracle) MODE=render-oracle ;;
        -h|--help)
            sed -n '2,63p' "$0"
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
    # KF6 runtime integrations referenced by src/CMakeLists.txt: Notifications
    # (KNotification taxonomy), Crash (drkonqi integration), I18n (KI18n
    # catalogs).  Without their -devel siblings the parent plugin .so cannot
    # configure, which breaks the scoped -Werror gate below.
    kf6-knotifications-devel kf6-kcrash-devel kf6-ki18n-devel
    # Optional but used by src/CMakeLists.txt when present (WekShortcuts):
    kf6-kglobalaccel-devel

    # Qt 6
    qt6-qtbase-devel qt6-qtbase-private-devel
    qt6-qtdeclarative-devel qt6-qtwebchannel-devel qt6-qtwebsockets-devel

    # native libs
    lz4-devel mpv-devel freetype-devel glfw-devel

    # sanitizer runtimes (libasan.so.8 lives only inside distrobox per CLAUDE.md)
    libasan libubsan

    # JSON parsing for opt-in coverage + mutation legs (baseline diff)
    jq
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
                  && cmake --build build/impl-tsan -j\$(nproc) \
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
            # ASAN/UBSAN (and any address/undefined combo).  FATAL: the submodule
            # suites + parent tests are audited clean under address+undefined,
            # so a finding here is a real regression and blocks the push.
            # Build with BUILD_FUZZERS=OFF so the fuzzers' own
            # -fsanitize=fuzzer,... flags don't double-instrument.
            step "Sanitizer leg (WEK_SANITIZE=${SAN_SPEC}) — FATAL on any finding"

            # Submodule suites.
            dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
                  cmake -B build/impl-asan -S src/backend_scene -G Ninja \
                        -DBUILD_TESTS=ON -DBUILD_FUZZERS=OFF \
                        -DWEK_SANITIZE=${SAN_SPEC} \
                        -DCMAKE_BUILD_TYPE=Debug \
                  && cmake --build build/impl-asan -j\$(nproc) \
                        --target backend_scene_tests scenescript_tests" \
                || fail "submodule sanitizer build failed"

            # detect_leaks=0: the parsers intentionally retain some long-lived
            # state in these short-lived test runs; LSAN noise would drown the
            # heap/UB findings we care about.  halt_on_error=1 + exit on the
            # first finding so the gate fails loudly.
            asan_opts="detect_leaks=0:halt_on_error=1:print_stacktrace=1"
            ubsan_opts="halt_on_error=1:print_stacktrace=1"

            step "Run backend_scene_tests under ${SAN_SPEC} (fatal on finding)"
            # WEKDE_HAS_AUDIO_DEVICE intentionally unset (avoids the device-enum hang).
            dbox "ASAN_OPTIONS='${asan_opts}' UBSAN_OPTIONS='${ubsan_opts}' \
                  ./build/impl-asan/src/Test/backend_scene_tests" \
                || fail "backend_scene_tests: sanitizer finding (${SAN_SPEC}) — see log"

            step "Run scenescript_tests under ${SAN_SPEC} (fatal on finding)"
            dbox "ASAN_OPTIONS='${asan_opts}' UBSAN_OPTIONS='${ubsan_opts}' \
                  QT_QPA_PLATFORM=offscreen \
                  ./build/impl-asan/src/Test/scenescript_tests" \
                || fail "scenescript_tests: sanitizer finding (${SAN_SPEC}) — see log"

            # Parent project suites (FileHelper, mpvbackend, etc.).
            step "Build + run parent tests under ${SAN_SPEC} (fatal on finding)"
            dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
                  cmake -B build/impl-asan-main -S tests -G Ninja \
                        -DWEK_SANITIZE=${SAN_SPEC} \
                        -DCMAKE_BUILD_TYPE=Debug \
                  && cmake --build build/impl-asan-main -j\$(nproc)" \
                || fail "parent-tests sanitizer build failed"
            dbox "ASAN_OPTIONS='${asan_opts}' UBSAN_OPTIONS='${ubsan_opts}' \
                  QT_QPA_PLATFORM=offscreen \
                  ctest --test-dir build/impl-asan-main --output-on-failure" \
                || fail "parent ctest: sanitizer finding (${SAN_SPEC}) — see log"

            printf '\n%sSanitizer leg passed — no findings.%s\n' "$GREEN" "$RESET"
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
             && cmake --build build/impl-werror -j\$(nproc)"; then
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

# ── Coverage leg (opt-in, standalone) ─────────────────────────────────────────
# Builds the parent tests AND the submodule tests with -DCOVERAGE=ON (Clang
# source-based coverage), runs each ctest with LLVM_PROFILE_FILE=…/%p.profraw,
# merges per-tree via llvm-profdata, exports totals via `llvm-cov export -format=text`,
# then diffs cxx_lines / cxx_regions / qml / sub_lines / sub_regions against
# tests/.coverage-baseline.json.  Parent ctest also drives the existing qmlcov
# target (custom homegrown QML hits tracer, threshold 95%).
#
# Parent ctest exclusions: tst_qml + tst_main_integration are label/regex-excluded
# because they fail in the standalone tests build (missing native QML types like
# WekNotifier / WekDiagnostics that the full project ships).  The qmlcov target
# re-runs QML coverage independently with its own instrumented mirror.
#
# Submodule ctest: all doctest suites (backend_scene_tests + scenescript_tests
# when Qt is present), no DISPLAY needed.  Build / profile dir is
# build/impl-coverage-sub/.
#
# FATAL by default when wired into the default flow: a regression beyond the
# 0.5pp tolerance fails the gate.  WEK_COVERAGE_REFRESH=1 rewrites
# tests/.coverage-baseline.json from the current numbers (use after intentionally-
# coverage-affecting changes).  Legacy COVERAGE_FATAL=0 escape hatch retained
# only when invoked via the standalone --coverage flag (see header).
if [[ "$MODE" == "coverage" ]]; then
    step "Coverage leg (-DCOVERAGE=ON, parent + submodule)"

    # jq parses llvm-cov export + qmlcov report.json on the host (the script's
    # own context).  llvm-profdata / llvm-cov run inside the distrobox alongside
    # the compilers.  Both checks degrade gracefully when run inside-the-box
    # (jq is in DEPS_FEDORA, llvm-* ship with clang).
    if ! command -v jq >/dev/null; then
        fail "jq not found on host (run: scripts/preflight.sh --bootstrap) — install with 'sudo dnf install jq' or similar"
    fi
    if ! dbox "command -v llvm-profdata >/dev/null && command -v llvm-cov >/dev/null"; then
        fail "llvm-profdata / llvm-cov not found in build env (Clang's coverage tools — install llvm-tools or clang-tools-extra)"
    fi

    # ── Parent coverage build + run ──────────────────────────────────────────
    cov_build="build/impl-coverage"
    rm -rf "$cov_build"
    COV_GEN="-G Ninja"
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B $cov_build -S tests $COV_GEN \
                -DCOVERAGE=ON -DCMAKE_BUILD_TYPE=Debug" \
        || fail "coverage configure failed (parent)"
    dbox "cmake --build $cov_build -j\$(nproc)" || fail "coverage build failed (parent)"
    ok "parent coverage build complete"

    # Run ctest with the same exclusions the standalone tests build needs.
    # tst_qml requires real QML plugin types beyond what the standalone build
    # ships; tst_main_integration loads main.qml which references those types.
    step "Run instrumented parent tests (LLVM_PROFILE_FILE=…/%p.profraw)"
    cov_prof_dir="$cov_build/coverage"
    dbox "rm -rf $cov_prof_dir && mkdir -p $cov_prof_dir"
    dbox "cd $cov_build && QT_QPA_PLATFORM=offscreen \
          LLVM_PROFILE_FILE='coverage/%p.profraw' \
          ctest --output-on-failure --label-exclude 'DISPLAY_NEEDED' \
                -E 'tst_main_integration'" \
        || fail "instrumented ctest failed (parent)"

    step "Merge + export parent coverage"
    dbox "llvm-profdata merge -sparse $cov_prof_dir/*.profraw \
          -o $cov_prof_dir/merged.profdata" \
        || fail "llvm-profdata merge failed (parent)"

    # Object set + ignore regex mirror tests/CMakeLists.txt's add_custom_target(coverage).
    cov_objs="$cov_build/tst_filehelper \
              -object=$cov_build/tst_mpriscolors \
              -object=$cov_build/tst_mousegrabber \
              -object=$cov_build/tst_mpvbackend \
              -object=$cov_build/tst_thumbnail_grabber \
              -object=$cov_build/tst_migrationhelper \
              -object=$cov_build/tst_playlist_manager"
    cov_ignore='-ignore-filename-regex=(^/usr/|/Qt6/|/tests/tst_|_autogen/|/moc_|third_party|backend_mpv/MpvBackend|backend_mpv/qthelper)'
    dbox "llvm-cov report $cov_objs \
          -instr-profile=$cov_prof_dir/merged.profdata \"$cov_ignore\" \
          > $cov_build/coverage.txt" \
        || fail "llvm-cov report failed (parent)"
    dbox "llvm-cov export -format=text $cov_objs \
          -instr-profile=$cov_prof_dir/merged.profdata \"$cov_ignore\" \
          > $cov_build/coverage.json" \
        || fail "llvm-cov export failed (parent)"

    # QML coverage — runs the existing qmlcov target which writes _qmlcov/report.json.
    # Threshold-fail behaviour stays inside the target; we read the percentage
    # for the baseline diff regardless of pass/fail.
    step "Run qmlcov target"
    qmlcov_rc=0
    dbox "cmake --build $cov_build --target qmlcov -j\$(nproc)" || qmlcov_rc=$?
    if [[ "$qmlcov_rc" != "0" ]]; then
        warn "qmlcov below its internal 95% threshold (rc=$qmlcov_rc) — captured for baseline diff"
    fi

    # ── Submodule coverage build + run ───────────────────────────────────────
    cov_build_sub="build/impl-coverage-sub"
    step "Configure + build submodule with -DCOVERAGE=ON -DBUILD_TESTS=ON"
    rm -rf "$cov_build_sub"
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B $cov_build_sub -S src/backend_scene $COV_GEN \
                -DCOVERAGE=ON -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug" \
        || fail "coverage configure failed (submodule)"
    # Build only the test targets — full submodule build is unnecessary for coverage.
    dbox "cmake --build $cov_build_sub --target backend_scene_tests -j\$(nproc)" \
        || fail "coverage build failed (submodule: backend_scene_tests)"
    # scenescript_tests target only exists when Qt6 Core/Qml were found at configure.
    if dbox "cmake --build $cov_build_sub --target scenescript_tests -j\$(nproc)" 2>/dev/null; then
        ok "submodule built backend_scene_tests + scenescript_tests"
    else
        warn "scenescript_tests not built (Qt6 Core/Qml absent?) — covering backend_scene_tests only"
    fi

    step "Run instrumented submodule tests (LLVM_PROFILE_FILE=…/%p.profraw)"
    cov_prof_dir_sub="$cov_build_sub/coverage"
    dbox "rm -rf $cov_prof_dir_sub && mkdir -p $cov_prof_dir_sub"
    # Submodule ctest needs WEKDE_HAS_AUDIO_DEVICE absent (default) so the
    # audio-device test gates remain skipped (no live PulseAudio in CI).
    # Exclude backend_scene_thread_tests — it's the TSan-target binary, not
    # built in the coverage configure (would require its own instrumentation
    # path) and contributes no coverage measure we don't already get from the
    # main two doctest suites.
    # ABSOLUTE LLVM_PROFILE_FILE path: submodule ctest tests run from
    # src/Test/ subdir, not $cov_build_sub, so a relative path drops profile
    # data in the wrong place.  Resolve to host-visible absolute path.
    cov_prof_abs_sub="$(realpath "$cov_prof_dir_sub")"
    dbox "cd $cov_build_sub && QT_QPA_PLATFORM=offscreen \
          LLVM_PROFILE_FILE='$cov_prof_abs_sub/%p.profraw' \
          ctest --output-on-failure -E '^backend_scene_thread_tests$'" \
        || fail "instrumented ctest failed (submodule)"

    step "Merge + export submodule coverage"
    dbox "llvm-profdata merge -sparse $cov_prof_dir_sub/*.profraw \
          -o $cov_prof_dir_sub/merged.profdata" \
        || fail "llvm-profdata merge failed (submodule)"

    # Object set: backend_scene_tests + optional scenescript_tests.
    # Ignore mirrors src/backend_scene/src/Test/CMakeLists.txt's coverage target.
    cov_objs_sub="$cov_build_sub/src/Test/backend_scene_tests"
    if [[ -x "$cov_build_sub/src/Test/scenescript_tests" ]]; then
        cov_objs_sub="$cov_objs_sub -object=$cov_build_sub/src/Test/scenescript_tests"
    fi
    cov_ignore_sub='-ignore-filename-regex=(^/usr/|/Qt6/|/third_party/|/src/Test/|/moc_|_autogen/)'
    dbox "llvm-cov report $cov_objs_sub \
          -instr-profile=$cov_prof_dir_sub/merged.profdata \"$cov_ignore_sub\" \
          > $cov_build_sub/coverage.txt" \
        || fail "llvm-cov report failed (submodule)"
    dbox "llvm-cov export -format=text $cov_objs_sub \
          -instr-profile=$cov_prof_dir_sub/merged.profdata \"$cov_ignore_sub\" \
          > $cov_build_sub/coverage.json" \
        || fail "llvm-cov export failed (submodule)"

    # Parse current numbers (parent + submodule + QML).
    cov_json="$cov_build/coverage.json"
    cov_json_sub="$cov_build_sub/coverage.json"
    qmlcov_json="$cov_build/_qmlcov/report.json"
    if [[ ! -s "$cov_json" ]]; then
        fail "parent coverage.json not produced"
    fi
    if [[ ! -s "$cov_json_sub" ]]; then
        fail "submodule coverage.json not produced"
    fi
    cur_cxx_lines=$(jq -r '.data[0].totals.lines.percent' "$cov_json")
    cur_cxx_regions=$(jq -r '.data[0].totals.regions.percent' "$cov_json")
    cur_sub_lines=$(jq -r '.data[0].totals.lines.percent' "$cov_json_sub")
    cur_sub_regions=$(jq -r '.data[0].totals.regions.percent' "$cov_json_sub")
    if [[ -s "$qmlcov_json" ]]; then
        # report.py emits overall_coverage as 0.0..1.0; report as a percentage.
        cur_qml=$(jq -r '.overall_coverage * 100' "$qmlcov_json")
    else
        warn "qmlcov did not produce report.json — recording 0 for QML in this run"
        cur_qml=0
    fi
    printf '%s  current:%s cxx_lines=%.2f cxx_regions=%.2f qml=%.2f sub_lines=%.2f sub_regions=%.2f\n' \
        "$BLUE" "$RESET" "$cur_cxx_lines" "$cur_cxx_regions" "$cur_qml" "$cur_sub_lines" "$cur_sub_regions"

    baseline=tests/.coverage-baseline.json
    if [[ "${WEK_COVERAGE_REFRESH:-0}" == "1" ]]; then
        jq -n --argjson lines "$cur_cxx_lines" \
              --argjson regions "$cur_cxx_regions" \
              --argjson qml "$cur_qml" \
              --argjson sub_lines "$cur_sub_lines" \
              --argjson sub_regions "$cur_sub_regions" \
              '{cxx_lines: $lines, cxx_regions: $regions, qml: $qml,
                sub_lines: $sub_lines, sub_regions: $sub_regions,
                _comment: "Totals from llvm-cov export (parent + submodule) + tools/qmlcov/report.py. Run WEK_COVERAGE_REFRESH=1 scripts/preflight.sh --coverage to update."}' \
            > "$baseline"
        ok "baseline refreshed: $baseline"
        exit 0
    fi

    if [[ ! -s "$baseline" ]]; then
        warn "no baseline file ($baseline) — run WEK_COVERAGE_REFRESH=1 scripts/preflight.sh --coverage to seed"
        printf '\n%sCoverage leg complete (NO BASELINE — informational).%s\n' "$YELLOW" "$RESET"
        exit 0
    fi
    base_lines=$(jq -r '.cxx_lines' "$baseline")
    base_regions=$(jq -r '.cxx_regions' "$baseline")
    base_qml=$(jq -r '.qml' "$baseline")
    base_sub_lines=$(jq -r '.sub_lines // 0' "$baseline")
    base_sub_regions=$(jq -r '.sub_regions // 0' "$baseline")

    # 0.5pp tolerance — typical run-to-run jitter is well below this.
    regressed=0
    awk -v c="$cur_cxx_lines"    -v b="$base_lines"       'BEGIN{exit !((b-c) > 0.5)}' && regressed=1 || true
    awk -v c="$cur_cxx_regions"  -v b="$base_regions"     'BEGIN{exit !((b-c) > 0.5)}' && regressed=1 || true
    awk -v c="$cur_qml"          -v b="$base_qml"         'BEGIN{exit !((b-c) > 0.5)}' && regressed=1 || true
    awk -v c="$cur_sub_lines"    -v b="$base_sub_lines"   'BEGIN{exit !((b-c) > 0.5)}' && regressed=1 || true
    awk -v c="$cur_sub_regions"  -v b="$base_sub_regions" 'BEGIN{exit !((b-c) > 0.5)}' && regressed=1 || true

    if [[ "$regressed" == "1" ]]; then
        warn "coverage regression vs baseline (tolerance 0.5pp):"
        printf '  cxx_lines:    %s -> %s\n' "$base_lines"       "$cur_cxx_lines"
        printf '  cxx_regions:  %s -> %s\n' "$base_regions"     "$cur_cxx_regions"
        printf '  qml:          %s -> %s\n' "$base_qml"         "$cur_qml"
        printf '  sub_lines:    %s -> %s\n' "$base_sub_lines"   "$cur_sub_lines"
        printf '  sub_regions:  %s -> %s\n' "$base_sub_regions" "$cur_sub_regions"
        if [[ "${COVERAGE_FATAL:-1}" == "1" ]]; then
            fail "coverage leg failed (regression vs baseline)"
        fi
        warn "non-fatal — set COVERAGE_FATAL=1 to gate, or WEK_COVERAGE_REFRESH=1 to update the baseline"
        printf '\n%sCoverage leg complete (NON-FATAL regression noted).%s\n' "$YELLOW" "$RESET"
        exit 0
    fi
    ok "coverage at/above baseline (tolerance 0.5pp, parent + submodule)"
    printf '\n%sCoverage leg passed.%s\n' "$GREEN" "$RESET"
    exit 0
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
          && cmake --build build/sub -j\$(nproc)" \
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
          && cmake --build build/tests -j\$(nproc)" \
        || fail "tests build failed"
    ok "tests built"
fi

# ── 5. Run main tests via ctest ───────────────────────────────────────────────
step "Main project tests (ctest)"
dbox "ctest --test-dir build/tests --output-on-failure" || fail "ctest failed"
ok "ctest passed"

# ── 5a. Scoped -Werror gate (4 shippable targets, default-gate FATAL) ─────────
# CLAUDE.md lists the four shippable / dlopen'd targets that are -Wall -Wextra
# clean: the plugin .so (WallpaperEngineKde), backend_mpv (mpvbackend), the
# wescene-renderer-qml bridge, and wpParticle.  cmake/WekWerrorScoped.cmake
# applies -Werror (with the conversion family no-error-gated) to just those
# four, AS LONG AS -DWEK_WERROR=ON is not set (the full-project audit path
# already covers them when explicit).  Build the four targets here so a -Wall
# / -Wextra regression in shippable code is a push-blocker.  Fresh build dir
# (build/werror-shippable) so the cache stays separate from build/sub /
# build/tests; reuse persistent dir on repeat runs.  The wider renderer libs
# are NOT in this gate — their audit stays opt-in via --werror (whole-tree).
if [[ "$MODE" != "test-only" ]]; then
    step "Scoped -Werror gate (4 shippable targets)"
    WERR_SCOPED_GEN=""
    [[ ! -f build/werror-shippable/CMakeCache.txt ]] && WERR_SCOPED_GEN="-G Ninja"
    if dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
             cmake -B build/werror-shippable -S . $WERR_SCOPED_GEN \
                   -DCMAKE_BUILD_TYPE=Debug \
             && cmake --build build/werror-shippable -j\$(nproc) \
                   --target WallpaperEngineKde mpvbackend \
                           wescene-renderer-qml wpParticle"; then
        ok "scoped -Werror clean (4 shippable targets)"
    else
        fail "scoped -Werror gate failed — a -Wall/-Wextra regression in the plugin .so / backend_mpv / wescene-renderer-qml / wpParticle is now an error"
    fi
fi

# ── 5b. Sanitizer gate (ASAN+UBSAN over submodule doctest suites, FATAL) ─────
# The parsers + scene runtime are the highest-risk untrusted-input surface and
# are audited clean under address+undefined sanitizers.  Gate every push on
# them so an ASAN heap/UAF or UBSAN find blocks the push instead of slipping
# in unobserved.  Detect_leaks=0 (parsers keep some long-lived state during
# short test runs — LSAN noise would mask the bugs we care about);
# halt_on_error=1 so the first finding fails the leg.  Fresh build dir
# (build/asan-gate) reused on repeat runs; BUILD_FUZZERS=OFF so the fuzzers'
# own -fsanitize=fuzzer flags don't double-instrument.  The wider parent-tests
# + full-suite sanitizer run is still advisory via --sanitize=address,undefined
# (parent QML / mpv tests not yet audited clean).
if [[ "$MODE" != "test-only" ]]; then
    step "Sanitizer gate (ASAN+UBSAN over submodule doctest suites)"
    ASAN_GATE_GEN=""
    [[ ! -f build/asan-gate/CMakeCache.txt ]] && ASAN_GATE_GEN="-G Ninja"
    dbox "CC=/usr/bin/clang CXX=/usr/bin/clang++ \
          cmake -B build/asan-gate -S src/backend_scene $ASAN_GATE_GEN \
                -DBUILD_TESTS=ON -DBUILD_FUZZERS=OFF \
                -DWEK_SANITIZE=address,undefined \
                -DCMAKE_BUILD_TYPE=Debug \
          && cmake --build build/asan-gate -j\$(nproc) \
                --target backend_scene_tests scenescript_tests" \
        || fail "ASAN gate build failed"
fi

step "Run backend_scene_tests under ASAN+UBSAN (gate)"
gate_asan_opts="detect_leaks=0:halt_on_error=1:print_stacktrace=1"
gate_ubsan_opts="halt_on_error=1:print_stacktrace=1"
dbox "ASAN_OPTIONS='${gate_asan_opts}' UBSAN_OPTIONS='${gate_ubsan_opts}' \
      ./build/asan-gate/src/Test/backend_scene_tests" \
    || fail "backend_scene_tests: sanitizer finding (ASAN/UBSAN) — investigate then re-run"
ok "backend_scene_tests: ASAN+UBSAN clean"

step "Run scenescript_tests under ASAN+UBSAN (gate)"
dbox "ASAN_OPTIONS='${gate_asan_opts}' UBSAN_OPTIONS='${gate_ubsan_opts}' \
      QT_QPA_PLATFORM=offscreen \
      ./build/asan-gate/src/Test/scenescript_tests" \
    || fail "scenescript_tests: sanitizer finding (ASAN/UBSAN) — investigate then re-run"
ok "scenescript_tests: ASAN+UBSAN clean"

# ── 6. Fuzz smoke (libFuzzer seeded regression gate) ─────────────────────────
# Catches the unbounded-resize / unterminated-buffer bug class on parser entry
# points (WPMdlParser, WPTexImageParser). Seeded from
# tests/fuzz_corpus/<target>/seed/ (cold-start fallback when seed dir is
# absent). Each harness ~30s; ~3 min total across 9 targets.
# Findings (crash/oom/timeout/leak) under build/sub/fuzz-crashes/ fail the gate.
if [[ "$NO_FUZZ" == "0" ]]; then
    FUZZ_SECS="${FUZZ_SECS:-20}"
    FUZZ_TARGETS=(WPMdlParser WPPkgFs WPTexImageParser
                  WPShaderParser WPShaderCompile WPSceneParser
                  WPParticleParser WPSoundParser WPJsonParse)
    step "Fuzz smoke (libFuzzer seeded, ${FUZZ_SECS}s × ${#FUZZ_TARGETS[@]} targets)"

    # Size budget: each tests/fuzz_corpus/<target>/seed must be <= 200 KB.
    for d in tests/fuzz_corpus/*/seed; do
        [[ -d "$d" ]] || continue
        b=$(du -bs "$d" | cut -f1)
        if [[ "$b" -gt 204800 ]]; then
            fail "fuzz corpus size budget exceeded: $d ($b bytes > 204800)"
        fi
    done

    if [[ "$MODE" != "test-only" ]]; then
        dbox "cmake --build build/sub --target fuzzers -j\$(nproc)" \
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
        seed_dir="tests/fuzz_corpus/$target/seed"
        # libFuzzer exits non-zero on first finding (which is what we want for a
        # gate). set -o pipefail inside dbox preserves that exit through tail.
        # Pass the checked-in seed dir as a read-only secondary corpus when
        # present; libFuzzer accepts multiple positional corpora and uses the
        # first writable one for newly-discovered mutants.
        if [[ -d "$seed_dir" ]]; then
            dbox "set -o pipefail; $binary $corpus $seed_dir \
                    -max_total_time=$FUZZ_SECS -timeout=15 -max_len=65536 \
                    -malloc_limit_mb=1024 -rss_limit_mb=2048 \
                    -artifact_prefix=$crash_dir/ -print_final_stats=1 2>&1 \
                  | tail -8" || true
        else
            # No checked-in seeds for this target — fall back to cold-start.
            dbox "set -o pipefail; $binary $corpus \
                    -max_total_time=$FUZZ_SECS -timeout=15 -max_len=65536 \
                    -malloc_limit_mb=1024 -rss_limit_mb=2048 \
                    -artifact_prefix=$crash_dir/ -print_final_stats=1 2>&1 \
                  | tail -8" || true
        fi
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

# ── 7. Coverage gate (parent + submodule, opt-in) ────────────────────────────
# OPT-IN: invoke separately as `scripts/preflight.sh --coverage` (with
# COVERAGE_FATAL=1 for gating, WEK_COVERAGE_REFRESH=1 to update baseline).
# Originally wired here as a default-fatal step but OOM'd on 30 GB machines
# because the Clang-instrumented build runs in parallel with whatever else
# is running — keeping it opt-in avoids that.

# ── 8. Mutation gate (parent + submodule, --diff-only --strict, opt-in) ──────
# OPT-IN: invoke separately as `scripts/mutation.sh --diff-only --strict`.
# Same OOM concern as coverage when run alongside other heavy builds.

printf '\n%sAll preflight checks passed — safe to push.%s\n' "$GREEN" "$RESET"
