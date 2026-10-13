#!/usr/bin/env bash
# Self-test for make-srpm.sh's handling of submodule state.
#
# make-srpm.sh used to run `git submodule update --init --force --recursive`
# unconditionally, which does `checkout -f` in every submodule: uncommitted
# edits to tracked submodule files were reverted, the branch was detached, and
# the build had already been tagged .dirty for edits it then threw away. This
# drives the script against a tiny parent + submodule fixture (never the real
# 17 GB tree) with stub rpmbuild/rpm, so it runs on the host in well under a
# second per case.
#
#   tools/scripts/tests/test-make-srpm-submodule.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

# The gate exports these; the cases below must not inherit them.
unset MULL_DIFF_BASE GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REAL_ROOT/tools/scripts/make-srpm.sh"
NAME=wallpaper-engine-kde-plugin-qt6
PASS=0
FAIL=0

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

# Scratch lives under build/, not /tmp (tmpfs is RAM).
mkdir -p "$REAL_ROOT/build/scratch"
scratch="$(mktemp -d "$REAL_ROOT/build/scratch/make-srpm-test.XXXX")"
trap 'rm -rf "$scratch"' EXIT

report() {  # report <name> <ok> <diagnostics>
    local name="$1" ok="$2" diag="${3:-}"
    if [[ "$ok" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        [[ -n "$diag" ]] && sed 's/^/        | /' <<<"$diag" | tail -20
        FAIL=$((FAIL + 1))
    fi
}

# check <name> <diag> <cmd...>: ok when the command succeeds.
check() {
    local name="$1" diag="$2"; shift 2
    if "$@" >/dev/null 2>&1; then report "$name" 1; else report "$name" 0 "$diag"; fi
}

export HOME="$scratch/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_TERMINAL_PROMPT=0

# Stub rpmbuild/rpm: the script only needs a src.rpm to appear whose name
# carries the stamped version, and rpm -qp to echo a changelog entry for it.
stubs="$scratch/stubs"
mkdir -p "$stubs"
cat > "$stubs/rpmbuild" <<'STUB'
#!/usr/bin/env bash
spec="$2"; outdir=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--define" && "$2" == _srcrpmdir\ * ]]; then outdir="${2#_srcrpmdir }"; fi
    shift
done
ver="$(sed -n 's/^Version: *//p' "$spec" | head -1)"
touch "$outdir/wallpaper-engine-kde-plugin-qt6-${ver}-1.src.rpm"
STUB
cat > "$stubs/rpm" <<'STUB'
#!/usr/bin/env bash
f="${@: -1}"; f="$(basename "$f")"
f="${f#wallpaper-engine-kde-plugin-qt6-}"; f="${f%.src.rpm}"
echo "packager - $f"
STUB
chmod +x "$stubs/rpmbuild" "$stubs/rpm"
export PATH="$stubs:$PATH"

# Fixture: a submodule with two commits (a.txt changes between them, b.txt does
# not) and a parent whose gitlink is the second one.
subsrc="$scratch/sub-src"
base="$scratch/base"
git init -q -b main "$subsrc"
printf 'one\n' > "$subsrc/a.txt"
printf 'stable\n' > "$subsrc/b.txt"
printf 'project(x)\n' > "$subsrc/CMakeLists.txt"
git -C "$subsrc" add -A && git -C "$subsrc" commit -q -m first
sub_first="$(git -C "$subsrc" rev-parse HEAD)"
printf 'two\n' > "$subsrc/a.txt"
git -C "$subsrc" commit -q -am second

git init -q -b main "$base"
printf '1.0\n' > "$base/VERSION"
mkdir -p "$base/rpm"
printf 'Name: x\nVersion: 0\nRelease: 1\n\n%%changelog\n' > "$base/rpm/wek.spec"
git -C "$base" add -A && git -C "$base" commit -q -m init
git -C "$base" submodule add -q "$subsrc" src/backend_scene
git -C "$base" commit -q -m "add submodule"

n=0
newcase() {  # newcase [--no-submodules] -> sets $repo, $out
    n=$((n + 1))
    repo="$scratch/case$n"; out="$scratch/out$n"
    git clone -q "$base" "$repo"
    [[ "${1:-}" == "--no-submodules" ]] || git -C "$repo" submodule update -q --init
    mkdir -p "$out"
}

run() {  # run: invokes the script in $repo; sets $rc, $err, $tarball, $version
    err="$scratch/err$n"
    (cd "$repo" && "$SCRIPT" --outdir "$out") >"$scratch/stdout$n" 2>"$err"
    rc=$?
    tarball="$(ls "$out"/"$NAME"-*.tar.gz 2>/dev/null | head -1)"
    version=""
    [[ -n "$tarball" ]] && version="$(basename "$tarball" .tar.gz)" && version="${version#"$NAME"-}"
}

intar() {  # intar <member> -> prints the member's content from the tarball
    tar -xzOf "$tarball" "$NAME-$version/$1" 2>/dev/null
}

echo "== make-srpm.sh submodule self-test =="

# A. Submodule at its recorded commit with a tracked edit: the edit survives
# the run, lands in the tarball, and the build is tagged .dirty.
newcase
echo LOCAL_EDIT >> "$repo/src/backend_scene/a.txt"
run
check "A  edit survives in the working tree" "$(cat "$err")" \
    grep -q LOCAL_EDIT "$repo/src/backend_scene/a.txt"
check "A  edit is packed into the tarball" "tarball=$tarball" \
    grep -q LOCAL_EDIT <(intar src/backend_scene/a.txt)
check "A  version carries .dirty" "version=$version" \
    test "${version%.dirty}" != "$version"

# B. Untracked files are not packed; the script says so, naming both.
newcase
: > "$repo/stray_parent.txt"
: > "$repo/src/backend_scene/stray_sub.txt"
run
check "B  warns about untracked files in parent and submodule" "$(cat "$err")" \
    bash -c 'grep -qi "untracked" "$1" && grep -q "stray_parent.txt" "$1" && grep -q "src/backend_scene/stray_sub.txt" "$1"' _ "$err"
check "B  untracked files alone do not tag the build .dirty" "version=$version" \
    test "${version%.dirty}" == "$version"

# C. Submodule on another commit with a tracked edit: refused, edit untouched.
# a.txt differs between the two commits (a checkout would conflict); b.txt does
# not (a plain update would carry the edit onto a base it was never written for).
for f in a.txt b.txt; do
    newcase
    git -C "$repo/src/backend_scene" checkout -q "$sub_first"
    echo LOCAL_EDIT >> "$repo/src/backend_scene/$f"
    run
    check "C  stale submodule + edit to $f: exits non-zero" "rc=$rc" test "$rc" -ne 0
    check "C  stale submodule + edit to $f: names src/backend_scene" "$(cat "$err")" \
        grep -q "src/backend_scene" "$err"
    check "C  stale submodule + edit to $f: edit still present" "" \
        grep -q LOCAL_EDIT "$repo/src/backend_scene/$f"
done

# D. Uninitialised submodule (fresh clone): populated and packed.
newcase --no-submodules
run
check "D  uninitialised submodule is populated and packed" "rc=$rc $(cat "$err")" \
    grep -q two <(intar src/backend_scene/a.txt)

# E. Clean stale submodule: moved to the recorded commit.
newcase
git -C "$repo/src/backend_scene" checkout -q "$sub_first"
run
check "E  clean stale submodule is moved to the gitlink" "rc=$rc $(cat "$err")" \
    test "$(git -C "$repo/src/backend_scene" rev-parse HEAD)" = "$(git -C "$repo" rev-parse HEAD:src/backend_scene)"
check "E  packed content is the gitlink's" "" grep -q two <(intar src/backend_scene/a.txt)

# F. Clean tree: committed content, no .dirty.
newcase
run
check "F  clean tree packs committed content" "rc=$rc $(cat "$err")" \
    grep -q two <(intar src/backend_scene/a.txt)
check "F  clean tree is not tagged .dirty" "version=$version" \
    test "${version%.dirty}" = "$version"

# G. Clean stale submodule: the update fixes it, so the tag must not say dirty.
newcase
git -C "$repo/src/backend_scene" checkout -q "$sub_first"
run
check "G  clean stale submodule is not tagged .dirty" "version=$version" \
    test "${version%.dirty}" = "$version"

# H. Submodule on a branch at the recorded commit: still on that branch.
newcase
git -C "$repo/src/backend_scene" checkout -q -b work
echo LOCAL_EDIT >> "$repo/src/backend_scene/a.txt"
run
check "H  submodule branch is not detached" "$(git -C "$repo/src/backend_scene" symbolic-ref HEAD 2>&1)" \
    test "$(git -C "$repo/src/backend_scene" symbolic-ref -q HEAD)" = "refs/heads/work"

echo
echo "make-srpm submodule self-test: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
