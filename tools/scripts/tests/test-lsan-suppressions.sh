#!/usr/bin/env bash
# Self-test for the ASAN gate's LSan wiring.
#
# preflight.sh's two sanitizer legs used to set ASAN_OPTIONS=detect_leaks=0
# process-wide, which hid a real system-library leak (libmpv's
# mpv_render_context_create, via libdrm's strdup) behind a comment that was
# only ever meant to cover the parsers' long-lived caches. The fix replaced
# the blanket disable with a suppressions file scoped to the one leak that's
# actually been seen, for the submodule doctest suites. The standalone leg's
# parent-ctest call site used to keep its own process-wide detect_leaks=0 for
# two targets that couldn't be suppressed by name; one of those (tst_main_
# integration) got a real ownership fix, and the exclusion for the other
# (tst_webprofileregistry, leaking inside libQt6WebEngineCore with no frame
# narrow enough to suppress by name) moved out of preflight.sh entirely, into
# a per-test ENVIRONMENT override in tests/CMakeLists.txt -- so every other
# parent-ctest target now runs under the same leak detection as the
# submodule suites. Losing any of that -- detect_leaks=0 creeping back
# process-wide, a call site missing LSAN_OPTIONS, or the per-test override
# losing its scoping or its named reason -- would silently reopen the gap
# this file exists to close. No cmake, no build: it reads preflight.sh's and
# tests/CMakeLists.txt's own text.
#
#   tools/scripts/tests/test-lsan-suppressions.sh
#
# Exits 0 when every case passes, 1 otherwise.

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
#    same line -- a partial edit that drops it from one of the five (or a
#    sixth site added later without it) would run that leg with LSan on but
#    unsuppressed, silently diverging from the others. The parent-ctest call
#    site now reuses ${asan_opts}/${lsan_opts} like the submodule suites
#    instead of keeping a dedicated variable, so it counts as one of these
#    five, not a separate exception -- the one remaining excluded target
#    (tst_webprofileregistry) is handled by check 3 instead, as a per-test
#    CMake override rather than a call-site-wide disable.
mapfile -t asan_lines < <(
    grep -nF "ASAN_OPTIONS='\${asan_opts}'" "$PREFLIGHT"
    grep -nF "ASAN_OPTIONS='\${gate_asan_opts}'" "$PREFLIGHT"
)
ok=1; missing=""
for line in "${asan_lines[@]}"; do
    [[ "$line" == *"LSAN_OPTIONS="* ]] || { ok=0; missing+="$line"$'\n'; }
done
[[ "${#asan_lines[@]}" -eq 5 ]] || ok=0
check "lsan_options_present_at_every_ASAN_OPTIONS_call_site (${#asan_lines[@]} found, want 5)" "$ok" \
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

# 4. The suppressions file must exist and carry exactly the one entry verified
#    against a live LSan run -- not empty (suppresses nothing, reintroduces
#    the noise the parser comment worried about) and not a broad first-party
#    prefix (hides a real future leak, the exact failure mode this item
#    closes).
ok=1; detail=""
if [[ ! -f "$LSAN_SUPP" ]]; then
    ok=0; detail="$LSAN_SUPP does not exist"
else
    mapfile -t entries < <(grep -vE '^\s*(#|$)' "$LSAN_SUPP")
    if [[ "${#entries[@]}" -ne 1 || "${entries[0]}" != "leak:mpv_render_context_create" ]]; then
        ok=0; detail="active entries: ${entries[*]:-<none>}"
    fi
fi
check "lsan_supp_has_exactly_the_verified_entry" "$ok" "$detail"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
