#!/usr/bin/env bash
# Self-test for the ASAN gate's LSan wiring.
#
# preflight.sh's two sanitizer legs used to set ASAN_OPTIONS=detect_leaks=0
# process-wide, which hid a real system-library leak (libmpv's
# mpv_render_context_create, via libdrm's strdup) behind a comment that was
# only ever meant to cover the parsers' long-lived caches. The fix replaced
# the blanket disable with a suppressions file scoped to the one leak that's
# actually been seen, for the submodule doctest suites. The standalone leg's
# parent-ctest call site is a deliberate, narrower exception: it still
# disables leak detection, but in its own variable, for two named targets
# that can't be suppressed by name yet, not process-wide for everything.
# Losing any of that -- detect_leaks=0 creeping back into the submodule
# suites, a call site missing LSAN_OPTIONS, or the parent-ctest exception
# losing its scoping or its named reason -- would silently reopen the gap
# this file exists to close. No cmake, no build: it reads preflight.sh's own
# text.
#
#   tools/scripts/tests/test-lsan-suppressions.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PREFLIGHT="$REAL_ROOT/tools/scripts/preflight.sh"
LSAN_SUPP="$REAL_ROOT/tools/scripts/lsan.supp"
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

# 1. The blanket disable must be gone from both sanitizer legs' ASAN_OPTIONS
#    strings. Reintroducing "detect_leaks=0" on either turns leak detection
#    back off for the whole binary, silently, the exact regression this item
#    closes.
hits="$(grep -nE '(^|[^_])(asan_opts|gate_asan_opts)="detect_leaks=0' "$PREFLIGHT" || true)"
ok=1; [[ -z "$hits" ]] || ok=0
check "detect_leaks_is_gone_from_both_asan_opts_assignments" "$ok" "still present: $hits"

# 2. Every submodule-suite ASAN_OPTIONS call site (the ones reading
#    ${asan_opts} or ${gate_asan_opts}) must also carry LSAN_OPTIONS on the
#    same line -- a partial edit that drops it from one of the four (or a
#    fifth site added later without it) would run that leg with LSan on but
#    unsuppressed, silently diverging from the others. The parent-ctest call
#    site is deliberately not one of these four -- see check 3.
mapfile -t asan_lines < <(
    grep -nF "ASAN_OPTIONS='\${asan_opts}'" "$PREFLIGHT"
    grep -nF "ASAN_OPTIONS='\${gate_asan_opts}'" "$PREFLIGHT"
)
ok=1; missing=""
for line in "${asan_lines[@]}"; do
    [[ "$line" == *"LSAN_OPTIONS="* ]] || { ok=0; missing+="$line"$'\n'; }
done
[[ "${#asan_lines[@]}" -eq 4 ]] || ok=0
check "lsan_options_present_at_every_submodule_ASAN_OPTIONS_call_site (${#asan_lines[@]} found, want 4)" "$ok" \
    "missing LSAN_OPTIONS: $missing"

# 3. The parent-ctest call site is the one deliberate exception: two of its
#    26 targets (tst_webprofileregistry, tst_main_integration) leak in ways
#    that can't be suppressed by name the way the mpv leak can -- one leaks
#    inside libQt6WebEngineCore with no allocation frame LSan can resolve to a
#    module or function, the other mixes a fixable first-party fixture leak
#    with QML engine-lifetime state that needs its own audit. Until that
#    follow-up work lands, this one call site keeps detect_leaks=0 -- but in
#    its own variable (parent_asan_opts), never reused for the submodule
#    suites, and named in a nearby comment so a future reader can tell "still
#    needed" from "leftover copy-paste."
block="$(awk '/ASAN\/UBSAN \(and any address\/undefined combo\)/,/Sanitizer leg passed/' "$PREFLIGHT")"
ok=1; detail=""
if [[ -z "$block" ]]; then
    ok=0; detail="couldn't find the --sanitize= case-arm block in $PREFLIGHT"
elif ! grep -q 'parent_asan_opts="detect_leaks=0' <<<"$block"; then
    ok=0; detail="parent_asan_opts=\"detect_leaks=0...\" not found in the case-arm block"
elif ! grep -q 'tst_webprofileregistry' <<<"$block" || ! grep -q 'tst_main_integration' <<<"$block"; then
    ok=0; detail="case-arm comment doesn't name both open targets (tst_webprofileregistry, tst_main_integration)"
fi
check "parent_ctest_call_site_keeps_a_scoped_detect_leaks_with_named_reason" "$ok" "$detail"

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
