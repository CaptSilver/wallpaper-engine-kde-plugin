#!/usr/bin/env bash
# Self-test for the -Werror gate's full-tree wiring.
#
# The whole-tree -Werror gate (preflight.sh's --werror leg and default-gate
# step 5a) used to configure only the root project, which never pulled in
# backend_scene_tests / scenescript_tests, so neither test binary had ever
# been built under -Werror. wescene-renderer (the static library holding
# WPSceneParser.cpp, SceneWallpaper.cpp and everything else that ships in the
# plugin) and standalone_view (the sceneviewer / sceneviewer-script debugging
# viewers) never received warning flags of any kind, -Werror or otherwise.
# The fix wired -DBUILD_TESTS=ON into both -Werror cmake lines and gave the
# doctest binaries, wescene-renderer and standalone_view real warning flags.
# Losing any of that -- a -Werror leg dropping BUILD_TESTS=ON, one of the two
# test targets losing its warning flags, or wescene-renderer / standalone_view
# never getting warn_opts wired back in -- would silently reopen the
# measurement gap this file exists to close. No cmake, no build: it reads
# preflight.sh's and the submodule CMakeLists.txt's own text.
#
#   tools/scripts/tests/test-werror-full-tree.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PREFLIGHT="$REAL_ROOT/tools/scripts/preflight.sh"
WEK_WARNINGS="$REAL_ROOT/src/backend_scene/cmake/WekWarnings.cmake"
TEST_CMAKE="$REAL_ROOT/src/backend_scene/src/Test/CMakeLists.txt"
SRC_CMAKE="$REAL_ROOT/src/backend_scene/src/CMakeLists.txt"
STANDALONE_CMAKE="$REAL_ROOT/src/backend_scene/standalone_view/CMakeLists.txt"
PASS=0
FAIL=0

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

check() {  # check <name> <0-or-1> <detail-on-fail>
    local name="$1" ok="$2" detail="$3"
    if [[ "$ok" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        [[ -n "$detail" ]] && printf '        %s\n' "$detail"
        FAIL=$((FAIL + 1))
    fi
}

echo "== -Werror full-tree wiring self-test =="

# 1. Both -Werror leg cmake configure lines in preflight.sh must carry
#    -DBUILD_TESTS=ON next to -DWEK_WERROR=ON -- otherwise the leg configures
#    the root project without ever pulling in the submodule's src/Test/ (or
#    the parent's own tests/), and the two doctest binaries stay unbuilt
#    under -Werror, exactly the gap this item closes.
mapfile -t werror_cmake_lines < <(grep -n 'cmake -B build/impl-werror -S \.\|cmake -B build/werror-shippable -S \.' "$PREFLIGHT")
ok=1; missing=""
for line in "${werror_cmake_lines[@]}"; do
    lineno="${line%%:*}"
    # The flags land on the next line in both call sites.
    next_lineno=$((lineno + 1))
    next_line="$(sed -n "${next_lineno}p" "$PREFLIGHT")"
    if [[ "$next_line" != *"-DWEK_WERROR=ON"* || "$next_line" != *"-DBUILD_TESTS=ON"* ]]; then
        ok=0; missing+="line $next_lineno: $next_line"$'\n'
    fi
done
[[ "${#werror_cmake_lines[@]}" -eq 2 ]] || ok=0
check "both_werror_legs_configure_with_BUILD_TESTS_ON (${#werror_cmake_lines[@]} found, want 2)" "$ok" "$missing"

# 2. WEK_DOCTEST_WERROR_EXEMPT_FLAGS must exist in WekWarnings.cmake and be
#    referenced by both test targets' target_compile_options in
#    src/Test/CMakeLists.txt -- otherwise doctest's own __COUNTER__/<ciso646>
#    diagnostics (call-site-anchored in first-party .cpp files, so -isystem
#    on the vendored header can't reach them) fail the build the moment
#    -Werror actually gets applied to either test target.
ok=1; detail=""
if ! grep -q 'WEK_DOCTEST_WERROR_EXEMPT_FLAGS' "$WEK_WARNINGS"; then
    ok=0; detail="WEK_DOCTEST_WERROR_EXEMPT_FLAGS not defined in $WEK_WARNINGS"
fi
check "doctest_werror_exempt_flags_defined_in_WekWarnings" "$ok" "$detail"

ok=1; detail=""
backend_line="$(grep -n 'target_compile_options(backend_scene_tests PRIVATE' "$TEST_CMAKE" || true)"
if [[ -z "$backend_line" || "$backend_line" != *"WEK_DOCTEST_WERROR_EXEMPT_FLAGS"* ]]; then
    ok=0; detail="backend_scene_tests's target_compile_options call doesn't reference WEK_DOCTEST_WERROR_EXEMPT_FLAGS: $backend_line"
fi
check "backend_scene_tests_references_doctest_exempt_flags" "$ok" "$detail"

ok=1; detail=""
scenescript_line="$(grep -n 'target_compile_options(scenescript_tests PRIVATE' "$TEST_CMAKE" || true)"
if [[ -z "$scenescript_line" ]]; then
    ok=0; detail="no target_compile_options(scenescript_tests PRIVATE ...) call in $TEST_CMAKE"
elif [[ "$scenescript_line" != *"WEK_DOCTEST_WERROR_EXEMPT_FLAGS"* ]]; then
    ok=0; detail="scenescript_tests's target_compile_options call doesn't reference WEK_DOCTEST_WERROR_EXEMPT_FLAGS: $scenescript_line"
fi
check "scenescript_tests_references_doctest_exempt_flags" "$ok" "$detail"

# 3. scenescript_tests's target_compile_options call must exist and reference
#    wek_warn_opts -- the conservative Wall/Wextra set, matching
#    ${PROJECT_NAME}-qml (which compiles the identical SceneBackend.cpp under
#    the same flags for the same Qt/QJSEngine noise reason). Before this
#    item, scenescript_tests had no target_compile_options call at all, so it
#    had never been checked under any warning flag.
ok=1; detail=""
if [[ -z "$scenescript_line" ]]; then
    ok=0; detail="no target_compile_options(scenescript_tests PRIVATE ...) call in $TEST_CMAKE"
elif [[ "$scenescript_line" != *"wek_warn_opts"* ]]; then
    ok=0; detail="scenescript_tests's target_compile_options call doesn't reference wek_warn_opts: $scenescript_line"
fi
check "scenescript_tests_has_wek_warn_opts" "$ok" "$detail"

# 4. src/CMakeLists.txt must apply warn_opts to the add_library(${PROJECT_NAME}
#    ...) target (wescene-renderer) -- every sibling library under src/
#    already builds under warn_opts; this one didn't, so SceneWallpaper.cpp
#    (the file MainHandler/RenderHandler live in) had never been compiled
#    under any warning flag.
ok=1; detail=""
if ! grep -qE 'target_compile_options\(\$\{PROJECT_NAME\}\s+PRIVATE\s+\$\{warn_opts\}\)|target_compile_options\(wescene-renderer\s+PRIVATE\s+\$\{warn_opts\}\)' "$SRC_CMAKE"; then
    ok=0; detail="no target_compile_options(\${PROJECT_NAME} PRIVATE \${warn_opts}) call in $SRC_CMAKE"
fi
check "wescene_renderer_gets_warn_opts" "$ok" "$detail"

# 5. standalone_view/CMakeLists.txt must include WekWarnings.cmake and apply
#    target_compile_options to both viewer targets (${PROJECT_NAME} /
#    sceneviewer, and ${PROJECT_NAME}-script / sceneviewer-script) --
#    glfwviewer.cpp and qmlviewer.cpp used to compile with no warning flags
#    at all.
ok=1; detail=""
if ! grep -q 'include(.*WekWarnings\.cmake' "$STANDALONE_CMAKE"; then
    ok=0; detail="no include(...WekWarnings.cmake) in $STANDALONE_CMAKE"
fi
check "standalone_view_includes_WekWarnings" "$ok" "$detail"

ok=1; detail=""
if ! grep -qE 'target_compile_options\(\$\{PROJECT_NAME\}\s+PRIVATE' "$STANDALONE_CMAKE"; then
    ok=0; detail="no target_compile_options(\${PROJECT_NAME} PRIVATE ...) in $STANDALONE_CMAKE"
fi
if ! grep -qE 'target_compile_options\(\$\{PROJECT_NAME\}-script\s+PRIVATE' "$STANDALONE_CMAKE"; then
    ok=0; detail+="${detail:+; }no target_compile_options(\${PROJECT_NAME}-script PRIVATE ...) in $STANDALONE_CMAKE"
fi
check "standalone_view_targets_get_compile_options" "$ok" "$detail"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
