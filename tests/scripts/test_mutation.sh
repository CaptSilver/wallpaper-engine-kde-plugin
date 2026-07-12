#!/usr/bin/env bash
# Test harness for tools/scripts/mutation.sh + tools/scripts/lib/mem.sh.
#
# Hermetic and fast: no real Mull run.  Fakes `nproc` and `cmake` on PATH, a
# fake /proc/meminfo via MEMINFO_FILE, and a throwaway git repo to drive the
# --diff-only mapping.  Protects the two things that keep the mutation gate from
# OOMing a box and staying cheap:
#   * mem_bounded_jobs() derives parallelism from available RAM, not just cores
#   * --diff-only fast-skips (no build) when the diff touches no mapped source
#
# No `set -e`: a test runner tallies failures and keeps going rather than dying
# on the first one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MUTATION="$REPO_ROOT/tools/scripts/mutation.sh"
MEMLIB="$REPO_ROOT/tools/scripts/lib/mem.sh"

PASS=0
FAIL=0
pass()    { echo "PASS [$1]"; PASS=$((PASS + 1)); }
failure() { echo "FAIL [$1]: $2"; FAIL=$((FAIL + 1)); }

# fake /proc/meminfo: pass avail="-" to omit MemAvailable (exercise the fallback)
make_meminfo() { # <file> <memavail_kb> [memtotal_kb]
    local f=$1 avail=$2 total=${3:-$2}
    {
        [[ "$avail" != "-" ]] && printf 'MemAvailable: %s kB\n' "$avail"
        printf 'MemTotal: %s kB\n' "$total"
    } > "$f"
}

make_bin() { # <dir> <nproc_value>
    local dir=$1 n=$2
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\necho %s\n' "$n" > "$dir/nproc"
    chmod +x "$dir/nproc"
}

# cmake stub: logs its args so a build's -j value is inspectable, and its mere
# creation of the log proves cmake was invoked (fast-skip must NOT invoke it).
make_cmake_stub() { # <bindir> <logfile>
    local bindir=$1 log=$2
    mkdir -p "$bindir"
    cat > "$bindir/cmake" <<EOF
#!/usr/bin/env bash
echo "cmake \$*" >> "$log"
exit 0
EOF
    chmod +x "$bindir/cmake"
}

# A PATH mirror of everything currently reachable EXCEPT jq.  The diff-mapping,
# fast-skip and build stages of mutation.sh must not require jq (it is only used
# to parse Mull's report), so the --diff-only subtests run jq-masked to prove it
# — matching the Fedora CI unit-test image, which ships without jq.
NOJQ_BIN=""
make_nojq_path() {
    NOJQ_BIN=$(mktemp -d)
    local d f b IFS=:
    for d in $PATH; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*; do
            b=$(basename "$f")
            [[ "$b" == jq ]] && continue
            [[ -e "$NOJQ_BIN/$b" ]] || ln -s "$f" "$NOJQ_BIN/$b" 2>/dev/null
        done
    done
}
make_nojq_path
trap '[[ -n "$NOJQ_BIN" ]] && rm -rf "$NOJQ_BIN"' EXIT

# throwaway repo whose HEAD~1 diff is exactly the listed files
make_gitrepo() { # <dir> <file...>
    local dir=$1; shift
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q
        git config user.email t@example.com
        git config user.name test
        for f in "$@"; do mkdir -p "$(dirname "$f")"; echo v1 > "$f"; done
        echo base > BASEFILE
        git add -A && git commit -qm base
        for f in "$@"; do echo v2 > "$f"; done
        git add -A && git commit -qm change
    )
}

# ── mem_bounded_jobs unit ─────────────────────────────────────────────────────
test_mem() { # <name> <avail_kb> <total_kb> <per_mb> <nproc> <expect>
    local name=$1 avail=$2 total=$3 per=$4 nproc=$5 expect=$6
    local d; d=$(mktemp -d)
    make_meminfo "$d/meminfo" "$avail" "$total"
    make_bin "$d/bin" "$nproc"
    local got
    got=$(PATH="$d/bin:$PATH" MEMINFO_FILE="$d/meminfo" \
          bash -c "source '$MEMLIB' 2>/dev/null && mem_bounded_jobs $per" 2>/dev/null) || true
    [[ "$got" == "$expect" ]] && pass "$name" || failure "$name" "got '$got', expected '$expect'"
    rm -rf "$d"
}

test_mem "mem: 4GB / 2048MB caps at 2 (not nproc=32)"   4194304  4194304 2048 32 2
test_mem "mem: 512MB / 2048MB clamps to 1 (never 0)"     524288   524288 2048 32 1
test_mem "mem: abundant RAM is still capped by nproc=4" 67108864 67108864 2048  4 4
test_mem "mem: MemAvailable absent → MemTotal fallback"        - 4194304 2048 32 2

# ── --diff-only fast-skip: unmapped diff → exit 0, no build ───────────────────
run_diff() { # <repo> <memfile> <bindir> -> sets OUT / RC
    local repo=$1 mem=$2 bin=$3
    RC=0
    # Stub dir first (cmake/nproc), then a jq-less mirror of the real PATH: these
    # paths must reach fast-skip / build without jq (see make_nojq_path).
    OUT=$(cd "$repo" && WEK_IN_CI=1 MEMINFO_FILE="$mem" PATH="$bin:$NOJQ_BIN" \
          "$MUTATION" --diff-only 2>&1) || RC=$?
}

test_fast_skip() {
    local name="fast-skip: diff touches no mapped source → exit 0, cmake never runs"
    local d; d=$(mktemp -d)
    make_gitrepo "$d/repo" README.md
    make_bin "$d/bin" 32
    make_cmake_stub "$d/bin" "$d/cmake.log"
    make_meminfo "$d/meminfo" 4194304
    run_diff "$d/repo" "$d/meminfo" "$d/bin"
    if [[ "$RC" -eq 0 ]] && grep -q "no changed sources mapped" <<<"$OUT" && [[ ! -f "$d/cmake.log" ]]; then
        pass "$name"
    else
        failure "$name" "rc=$RC, cmake_ran=$([[ -f $d/cmake.log ]] && echo yes || echo no)"
    fi
    rm -rf "$d"
}
test_fast_skip

test_submodule_not_skipped() {
    local name="submodule diff maps to backend_scene_tests (not fast-skipped)"
    local d; d=$(mktemp -d)
    make_gitrepo "$d/repo" src/backend_scene/src/foo.cpp
    make_bin "$d/bin" 32
    make_cmake_stub "$d/bin" "$d/cmake.log"
    make_meminfo "$d/meminfo" 4194304
    run_diff "$d/repo" "$d/meminfo" "$d/bin"
    if grep -q "backend_scene_tests" <<<"$OUT" && ! grep -q "no changed sources mapped" <<<"$OUT"; then
        pass "$name"
    else
        failure "$name" "did not map submodule diff to backend_scene_tests"
    fi
    rm -rf "$d"
}
test_submodule_not_skipped

test_build_jobs_bounded() {
    local name="parent build uses RAM-bounded -j (not -j\$(nproc))"
    local d; d=$(mktemp -d)
    make_gitrepo "$d/repo" src/FileHelper.cpp
    make_bin "$d/bin" 32
    make_cmake_stub "$d/bin" "$d/cmake.log"
    make_meminfo "$d/meminfo" 4194304   # 4096MB / 1536MB per build job = 2
    run_diff "$d/repo" "$d/meminfo" "$d/bin"
    if [[ -f "$d/cmake.log" ]] && grep -qE -- '--build .* -j2( |$)' "$d/cmake.log" \
        && ! grep -qE -- '-j32( |$)' "$d/cmake.log"; then
        pass "$name"
    else
        failure "$name" "build cmd: $(grep -- '--build' "$d/cmake.log" 2>/dev/null || echo '(cmake not logged)')"
    fi
    rm -rf "$d"
}
test_build_jobs_bounded

echo
echo "Tests: $PASS passed, $FAIL failed."
exit $FAIL
