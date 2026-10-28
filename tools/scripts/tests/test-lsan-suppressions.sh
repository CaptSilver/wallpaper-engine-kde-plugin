#!/usr/bin/env bash
# Static wiring checks plus real ASAN/UBSAN/LSan regressions for the default
# gate. Only the isolated real-GPU suite omits LSan; the opt-in sanitizer leg
# retains full-suite leak diagnostics. Run in the gate's compiler environment.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PREFLIGHT="$REAL_ROOT/tools/scripts/preflight.sh"
LSAN_SUPP="$REAL_ROOT/tools/scripts/lsan.supp"
TESTS_CMAKE="$REAL_ROOT/tests/CMakeLists.txt"
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

echo "== LSan suppressions self-test =="

# 1. The blanket disable must be gone from every sanitizer-leg ASAN_OPTIONS
#    assignment in preflight.sh, including the parent-ctest call site's old
#    dedicated variable (now deleted). Reintroducing "detect_leaks=0" here,
#    process-wide or on a leftover parent_asan_opts, turns leak detection
#    back off silently -- the exact regression this item closes.
hits="$(grep -nE '(^|[^_])(asan_opts|gate_asan_opts|parent_asan_opts)="detect_leaks=0' "$PREFLIGHT" || true)"
ok=1; [[ -z "$hits" ]] || ok=0
check "detect_leaks_is_gone_from_every_asan_opts_assignment" "$ok" "still present: $hits"

leftover="$(grep -n 'parent_asan_opts' "$PREFLIGHT" || true)"
ok=1; [[ -z "$leftover" ]] || ok=0
check "parent_asan_opts_variable_no_longer_exists" "$ok" "still present: $leftover"

# 2. Every parent-suite-or-submodule ASAN_OPTIONS call site (the ones reading
#    ${asan_opts} or ${gate_asan_opts}) must also carry LSAN_OPTIONS on the
#    same line -- a partial edit that drops it from one of the six (or a
#    seventh site added later without it) would run that leg with LSan on but
#    unsuppressed, silently diverging from the others. The parent-ctest call
#    site now reuses ${asan_opts}/${lsan_opts} like the submodule suites
#    instead of keeping a dedicated variable, so it counts as one of these
#    six, not a separate exception -- the one remaining excluded target
#    (tst_webprofileregistry) is handled by check 3 instead, as a per-test
#    CMake override rather than a call-site-wide disable.
mapfile -t asan_lines < <(
    grep -nF "ASAN_OPTIONS='\${asan_opts}'" "$PREFLIGHT"
    grep -nF "ASAN_OPTIONS='\${gate_asan_opts}" "$PREFLIGHT"
)
ok=1; missing=""
for line in "${asan_lines[@]}"; do
    [[ "$line" == *"LSAN_OPTIONS="* ]] || { ok=0; missing+="$line"$'\n'; }
done
[[ "${#asan_lines[@]}" -eq 6 ]] || ok=0
check "lsan_options_present_at_every_ASAN_OPTIONS_call_site (${#asan_lines[@]} found, want 6)" "$ok" \
    "missing LSAN_OPTIONS: $missing"

# 3. tst_webprofileregistry is the one remaining exception: it leaks inside
#    libQt6WebEngineCore, and a live LSan run found no single stack frame
#    common to every leak block (most bottom out in unresolved Chromium-
#    internal addresses), so there's no name narrow enough for lsan.supp the
#    way the mpv leak is suppressed. Unlike the old parent_asan_opts variable,
#    this exclusion now lives as a per-test ENVIRONMENT override in
#    tests/CMakeLists.txt, scoped to this one target -- every other
#    parent-ctest target runs with leak detection on by default (check 2).
block="$(awk '/set_tests_properties\(tst_webprofileregistry/,/\)/' "$TESTS_CMAKE")"
comment="$(grep -B8 'set_tests_properties(tst_webprofileregistry' "$TESTS_CMAKE" || true)"
ok=1; detail=""
if [[ ! -f "$TESTS_CMAKE" ]]; then
    ok=0; detail="$TESTS_CMAKE does not exist"
elif [[ -z "$block" ]]; then
    ok=0; detail="couldn't find set_tests_properties(tst_webprofileregistry ...) in $TESTS_CMAKE"
elif ! grep -q 'ASAN_OPTIONS=.*detect_leaks=0' <<<"$block"; then
    ok=0; detail="tst_webprofileregistry's ENVIRONMENT string doesn't set ASAN_OPTIONS=...detect_leaks=0"
elif ! grep -qi 'leak' <<<"$comment"; then
    ok=0; detail="no nearby comment names the leak reason for tst_webprofileregistry's override"
fi
check "tst_webprofileregistry_keeps_a_scoped_cmake_override_with_named_reason" "$ok" "$detail"

# 4. The suppressions file must carry only the entries verified
#    against a live LSan run -- not empty (suppresses nothing, reintroduces
#    the noise the parser comment worried about) and not a broad first-party
#    prefix (hides a real future leak, the exact failure mode this item
#    closes).
ok=1; detail=""
if [[ ! -f "$LSAN_SUPP" ]]; then
    ok=0; detail="$LSAN_SUPP does not exist"
else
    mapfile -t entries < <(grep -vE '^\s*(#|$)' "$LSAN_SUPP")
    if [[ "${#entries[@]}" -ne 2 || "${entries[0]}" != "leak:mpv_render_context_create" || "${entries[1]}" != "leak:FcConfigParseAndLoad" ]]; then
        ok=0; detail="active entries: ${entries[*]:-<none>}"
    fi
fi
check "lsan_supp_has_only_the_verified_entries" "$ok" "$detail"


# 5. Execute the actual default sanitizer run block with a tiny doctest binary.
# Intentional faults must remain fatal, including in the GPU-only process.
# This tests real sanitizer exit codes, not grepping simulated error messages.
probe_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "$probe_dir"' EXIT
mkdir -p "$probe_dir/build/asan-gate/src/Test"
probe_bin="$probe_dir/build/asan-gate/src/Test/backend_scene_tests"
read -r -a font_flags <<<"$(pkg-config --cflags --libs fontconfig)"
if ! "${CXX:-/usr/bin/clang++}" -std=c++17 -g -O0 -fno-omit-frame-pointer \
    -fsanitize=address,undefined \
    -I"$REAL_ROOT/src/backend_scene/third_party/nlohmann/tests/thirdparty/doctest" \
    -x c++ - -o "$probe_bin" "${font_flags[@]}" <<'CPP'
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest.h>
#include <fontconfig/fontconfig.h>
#include <climits>
#include <cstdlib>
#include <cstring>

static bool mode(const char* value) {
    const char* actual = std::getenv("SANITIZER_PROBE");
    return actual && std::strcmp(actual, value) == 0;
}
__attribute__((noinline)) static void leak() {
    void* p = std::malloc(123);
    REQUIRE((p != nullptr));
    asm volatile("" : : "r"(p) : "memory");
}
__attribute__((noinline)) static void fault() {
    auto* p = static_cast<volatile char*>(std::malloc(8));
    REQUIRE((p != nullptr));
    std::free(const_cast<char*>(p));
    *p = 1;
}
static void overflow() {
    volatile int n = INT_MAX;
    n += 1;
}
TEST_SUITE("CPU") {
    TEST_CASE("first-party memory and ownership") {
        if (mode("cpu-leak")) leak();
        if (mode("cpu-asan")) fault();
        if (mode("cpu-ubsan")) overflow();
        if (mode("font")) {
            auto* p = FcPatternCreate();
            REQUIRE((p != nullptr));
            FcPatternAddString(p, FC_FAMILY, reinterpret_cast<const FcChar8*>("sans-serif"));
            REQUIRE(FcConfigSubstitute(nullptr, p, FcMatchPattern));
            FcPatternDestroy(p);
        }
        // A leaked application-owned pattern must not match config parsing.
        if (mode("pattern-leak")) {
            auto* p = FcPatternCreate();
            REQUIRE((p != nullptr));
            FcPatternAddString(p, FC_FAMILY, reinterpret_cast<const FcChar8*>("sans-serif"));
        }
    }
}
TEST_SUITE("HWVideoTextureDecoder GPU buffer lifetime") {
    TEST_CASE("external shutdown allocation") {
        leak();
        if (mode("gpu-asan")) fault();
        if (mode("gpu-ubsan")) overflow();
        REQUIRE_FALSE(mode("gpu-assert"));
    }
}
CPP
then
    echo "FAIL: could not build sanitizer scope regression" >&2
    exit 1
fi
# SceneScript has its own executable in production; this fixture selects only
# the CPU cases so an accidental process-wide disable also loses a leak here.
cat > "$probe_dir/build/asan-gate/src/Test/scenescript_tests" <<'SH'
#!/usr/bin/env bash
if [[ "${SANITIZER_PROBE:-}" == scene-leak ]]; then export SANITIZER_PROBE=cpu-leak; fi
exec ./build/asan-gate/src/Test/backend_scene_tests --test-suite=CPU
SH
chmod +x "$probe_dir/build/asan-gate/src/Test/scenescript_tests"
{
    printf 'set -euo pipefail\n'
    printf '_PF_DIR=%q\n' "$REAL_ROOT/tools/scripts"
    printf 'dbox() { bash -c "$1"; }\nstep() { :; }\nok() { :; }\nfail() { echo "$*" >&2; exit 1; }\n'
    awk '/^step "Run backend_scene_tests under ASAN\+UBSAN \(gate\)"/ {copy=1}
         /^# .*6\. Fuzz smoke/ {copy=0}
         copy' "$PREFLIGHT"
} > "$probe_dir/run.sh"
# Pin env options via the production block; inherited sanitizer variables must
# not turn off a fault or inject an unrelated suppression.
for scenario in clean font cpu-leak pattern-leak cpu-asan cpu-ubsan gpu-asan gpu-ubsan gpu-assert scene-leak; do
    rc=0
    (cd "$probe_dir" && SANITIZER_PROBE="$scenario" bash run.sh) > "$probe_dir/$scenario.log" 2>&1 || rc=$?
    ok=0
    case "$scenario" in
        clean|font) [[ "$rc" -eq 0 ]] && ok=1 ;;
        cpu-leak|pattern-leak|scene-leak) [[ "$rc" -ne 0 ]] && grep -q 'LeakSanitizer' "$probe_dir/$scenario.log" && ok=1 ;;
        *-asan) [[ "$rc" -ne 0 ]] && grep -q 'heap-use-after-free' "$probe_dir/$scenario.log" && ok=1 ;;
        *-ubsan) [[ "$rc" -ne 0 ]] && grep -q 'signed integer overflow' "$probe_dir/$scenario.log" && ok=1 ;;
        gpu-assert) [[ "$rc" -ne 0 ]] && grep -q 'REQUIRE_FALSE' "$probe_dir/$scenario.log" && ok=1 ;;
    esac
    check "runtime sanitizer scope: $scenario" "$ok" "exit=$rc"
    [[ "$ok" -eq 1 ]] || cat "$probe_dir/$scenario.log"
done

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
