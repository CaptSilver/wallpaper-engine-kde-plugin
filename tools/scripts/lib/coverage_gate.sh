# tools/scripts/lib/coverage_gate.sh — coverage gate wrapper for preflight.sh.
#
# The in-gate wrapper used to re-derive a pass/fail verdict from COVERAGE_FATAL
# after the nested `--coverage` leg had already returned an exit code computed
# from that same variable -- a second decision from the same input, and it
# disagreed with the first one in both directions (see git history on the
# wrapper block this replaces). The leg's own exit code already IS the
# fatal-or-tolerated verdict; the wrapper's only job is to act on it.
#
# run_coverage_gate <coverage-cmd...>
#   Runs <coverage-cmd>; on a nonzero exit, calls fail() (must already be
#   defined by the caller). Prints nothing of its own on success -- the
#   nested leg's own stdout already states pass/regression/tolerated.
run_coverage_gate() {
    "$@" || fail "coverage gate failed — see the leg output above"
}
