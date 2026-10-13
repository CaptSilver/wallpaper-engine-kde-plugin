# shellcheck shell=bash
# How preflight.sh reads a tools/scripts/mutation.sh exit code.  Kept apart from
# preflight so every branch is testable (tools/scripts/tests/test-mutation-rc.sh).
#
# mutation_rc_verdict <rc>
# Prints "<ok|warn|fail><TAB><message>".  MUTATION_FATAL=1 turns the codes that
# mean "nothing was measured" (2, 78) and new survivors (anything else) into
# fail; 79 stays a warning even then, since those lines belong to a full run.
mutation_rc_verdict() {
    local rc="$1" fatal="${MUTATION_FATAL:-0}"
    case "$rc" in
        0)  printf 'ok\tmutation gate: no new surviving mutants vs baseline\n' ;;
        77) printf 'ok\tmutation gate skipped (Mull runner/build unavailable)\n' ;;
        79) printf 'warn\tmutation gate skipped: diff is past MULL_DIFF_MAX_LINES — measure it with a full mutation run (tools/scripts/mutation.sh --target <target>)\n' ;;
        2)  if [[ "$fatal" == "1" ]]; then
                printf 'fail\tmutation gate could not start (bad invocation, e.g. an unresolvable MULL_DIFF_BASE; see above) — fix the invocation rather than treating it as a pass\n'
            else
                printf 'warn\tmutation gate could not start (bad invocation, e.g. an unresolvable MULL_DIFF_BASE; see above)\n'
            fi ;;
        78) if [[ "$fatal" == "1" ]]; then
                printf 'fail\tmutation gate could not measure — fix the run rather than treating it as a pass\n'
            else
                printf 'warn\tmutation gate produced no measurement (see above) — no survivor diff was possible\n'
            fi ;;
        *)  if [[ "$fatal" == "1" ]]; then
                printf "fail\tmutation gate: new surviving mutant(s) — fix tests or run 'tools/scripts/mutation.sh --refresh-baseline'\n"
            else
                printf 'warn\tmutation gate: new surviving mutant(s) (non-fatal — set MUTATION_FATAL=1 to gate)\n'
            fi ;;
    esac
}
