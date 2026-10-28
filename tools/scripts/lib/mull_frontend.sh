# shellcheck shell=bash
# Whether Mull's compile-time frontend read the committed mull.yml.
#
# The frontend (the -fpass-plugin that embeds mutants into object code) decides
# which mutants exist at all; mull-runner can only run fewer of them.  The
# frontend reads MULL_CONFIG while compiling, and with no config it falls back
# to cxx_default, which has no bitwise or logical mutators.  The submodule's
# mull.yml asks for those families, so any one of them in the binary proves the
# config reached the compiler; their absence means it did not.  Testable on its
# own (tools/scripts/tests/test-mutation-gate.sh).
#
# mull_frontend_config_reached <binary>
# Returns 0 when <binary> embeds a cxx_bitwise or cxx_logical mutant.
mull_frontend_config_reached() {
    local bin="$1"
    [[ -f "$bin" ]] || return 1
    # Captured rather than piped into grep -q: with pipefail, grep -q exiting at
    # the first match kills the producer with SIGPIPE and reads as a miss.
    local hit
    hit="$(grep -aoE -m1 'cxx_(and_to_or|or_to_and|xor_to_or|lshift_to_rshift|rshift_to_lshift|bitwise_not_to_noop|remove_negation):' "$bin")"
    [[ -n "$hit" ]]
}
