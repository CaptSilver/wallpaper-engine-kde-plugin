#!/usr/bin/env bash
# Regression test for qmltestrunner's own -maxwarnings cap (default 2000):
# once a noisy early test file exhausts the budget, qmltestrunner silently
# drops every later console message for the rest of the run -- including
# every __COV_TICK__ marker the qmlcov coverage tracer depends on, and any
# real QWARN a normal tst_qml run would otherwise report.
#
# This drives the REAL invocation resolved from tests/CMakeLists.txt (via
# `ctest --show-only`), with only the -input directory swapped to a
# throwaway fixture, rather than a private reimplementation of the
# qmltestrunner call -- a self-contained reimplementation would pass even if
# tests/CMakeLists.txt's actual COMMAND regressed.
set -uo pipefail

SKIP_CODE=77

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <ctest-build-dir> <tests-source-dir>" >&2
    exit 1
fi
BUILD_DIR=$(cd "$1" && pwd)
TESTS_SRC_DIR=$(cd "$2" && pwd)
CMAKELISTS="$TESTS_SRC_DIR/CMakeLists.txt"

QMLTESTRUNNER=""
for candidate in qmltestrunner-qt6 qmltestrunner6 qmltestrunner; do
    if command -v "$candidate" >/dev/null 2>&1; then
        QMLTESTRUNNER=$candidate
        break
    fi
done
if [[ -z "$QMLTESTRUNNER" ]]; then
    echo "qmltestrunner not found on PATH -- skipping"
    exit "$SKIP_CODE"
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found on PATH -- skipping"
    exit "$SKIP_CODE"
fi

fail=0

# Structural check: both real invocations must carry the flag. On its own
# this would pass on a source-text match that never reaches qmltestrunner
# (a typo'd COMMAND list, say), so it's paired below with actually driving
# the resolved, live tst_qml command against a budget-exhausting fixture.
if ! awk '/add_custom_target\(qmlcov/,/USES_TERMINAL/' "$CMAKELISTS" | grep -q -- '-maxwarnings 0'; then
    echo "FAIL: qmlcov custom target's qmltestrunner invocation is missing -maxwarnings 0"
    fail=1
fi

if ! awk '/add_test\(NAME tst_qml/,/WORKING_DIRECTORY/' "$CMAKELISTS" | grep -q -- '-maxwarnings 0'; then
    echo "FAIL: tst_qml add_test's COMMAND is missing -maxwarnings 0"
    fail=1
fi

SCRATCH_DIR="$BUILD_DIR/warning_budget_probe"
rm -rf "$SCRATCH_DIR"
FIXTURE_DIR="$SCRATCH_DIR/fixture"
mkdir -p "$FIXTURE_DIR"

# tst_NoisyFirst sorts before tst_Quiet, so qmltestrunner's default
# alphabetical directory scan runs it first and can exhaust the warning
# budget before Quiet's marker ever gets a chance to print.
cat > "$FIXTURE_DIR/tst_NoisyFirst.qml" <<'EOF'
import QtQuick 2.15
import QtTest 1.2

TestCase {
    name: "NoisyFirst"
    function test_noisy() {
        for (var i = 0; i < 2100; i++) {
            console.warn("noise");
        }
        verify(true);
    }
}
EOF

cat > "$FIXTURE_DIR/tst_Quiet.qml" <<'EOF'
import QtQuick 2.15
import QtTest 1.2

TestCase {
    name: "Quiet"
    function test_quiet() {
        console.warn("MARKER_QUIET_TICKED");
        verify(true);
    }
}
EOF

# Ask ctest what it would really run for tst_qml, then swap only the -input
# directory to the fixture above -- everything else (the binary, flags,
# ENVIRONMENT, WORKING_DIRECTORY) stays exactly what production runs.
SHOW_JSON="$SCRATCH_DIR/show.json"
if ! ctest --test-dir "$BUILD_DIR" --show-only=json-v1 -R '^tst_qml$' > "$SHOW_JSON" 2>&1; then
    echo "FAIL: ctest --show-only could not resolve tst_qml (is $BUILD_DIR configured from tests/CMakeLists.txt?)"
    cat "$SHOW_JSON"
    exit 1
fi

RUN_SCRIPT="$SCRATCH_DIR/run_swapped.sh"
if ! python3 - "$SHOW_JSON" "$FIXTURE_DIR" "$RUN_SCRIPT" <<'PYEOF'
import json
import shlex
import sys

show_path, fixture_dir, run_script_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(show_path) as f:
    data = json.load(f)

tests = [t for t in data.get("tests", []) if t.get("name") == "tst_qml"]
if not tests:
    sys.exit("tst_qml not found in ctest --show-only output")
test = tests[0]

command = list(test["command"])
try:
    idx = command.index("-input")
except ValueError:
    sys.exit("tst_qml command has no -input argument to swap")
command[idx + 1] = fixture_dir

props = {p["name"]: p["value"] for p in test.get("properties", [])}
env = props.get("ENVIRONMENT", [])
workdir = props.get("WORKING_DIRECTORY", ".")

with open(run_script_path, "w") as f:
    f.write("#!/usr/bin/env bash\n")
    f.write("set -uo pipefail\n")
    f.write("cd {}\n".format(shlex.quote(workdir)))
    for kv in env:
        key, _, val = kv.partition("=")
        f.write("export {}={}\n".format(key, shlex.quote(val)))
    f.write("exec {}\n".format(" ".join(shlex.quote(c) for c in command)))
PYEOF
then
    echo "FAIL: could not build the swapped invocation from ctest --show-only output"
    exit 1
fi
chmod +x "$RUN_SCRIPT"

RUN_LOG="$SCRATCH_DIR/run.log"
bash "$RUN_SCRIPT" > "$RUN_LOG" 2>&1
run_rc=$?

if ! grep -q MARKER_QUIET_TICKED "$RUN_LOG"; then
    echo "FAIL: MARKER_QUIET_TICKED did not survive the real tst_qml invocation against a budget-exhausting fixture (qmltestrunner exit $run_rc) -- -maxwarnings 0 is missing from the resolved command"
    echo "---- tail of captured output ($RUN_LOG) ----"
    tail -n 20 "$RUN_LOG"
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    exit 1
fi

echo "PASS: -maxwarnings 0 is present in tests/CMakeLists.txt and survives a budget-exhausting fixture in the resolved tst_qml invocation"
exit 0
