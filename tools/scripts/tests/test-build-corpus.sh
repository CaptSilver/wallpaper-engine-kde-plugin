#!/usr/bin/env bash
# Self-test for build-corpus.sh's filesystem-seeding loops.
#
# build-corpus.sh runs three independent passes against a Steam Workshop
# tree -- loose .mdl/.tex files copied straight in, .mdl/.tex pulled out of
# each scene.pkg via wp-pkg extract, and the raw .pkg archives themselves --
# and until now none of it ran under a test harness. A regression in any one
# pass (wrong destination path, a flipped -size sign, wp-pkg's argument order
# changing) would surface only the next time someone runs a real fuzz session
# and finds a seed directory sitting empty, indistinguishable from a cold
# start. This drives build-corpus.sh against a synthetic workshop dir and a
# stub wp-pkg binary -- no cmake, no real Workshop content, no compiler,
# well under a second total.
#
#   tools/scripts/tests/test-build-corpus.sh
#
# Exits 0 when every case passes, 1 otherwise.

set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_CORPUS="$REAL_ROOT/tools/scripts/fuzz/build-corpus.sh"
PASS=0
FAIL=0
TMPS=()

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

cleanup() { for d in "${TMPS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

report() {  # report <name> <ok> <diagnostics>
    local name="$1" ok="$2" diag="$3"
    if [[ "$ok" == "1" ]]; then
        printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        [[ -n "$diag" ]] && sed 's/^/        | /' <<<"$diag" | tail -20
        FAIL=$((FAIL + 1))
    fi
}

echo "== build-corpus.sh seeding self-test =="

# Shared scratch tree: both cases below run against a single build-corpus.sh
# invocation (not two separate runs), so all fixtures -- including the
# oversized ones case 2 needs -- are written up front.
scratch="$(mktemp -d)"
TMPS+=("$scratch")

mkdir -p "$scratch/workshop/1111111111" "$scratch/workshop/2222222222" \
         "$scratch/build/sub/tools"

printf 'mdl-body'      > "$scratch/workshop/1111111111/model.mdl"
printf 'tex-body'      > "$scratch/workshop/1111111111/image.tex"
printf 'raw-pkg-bytes' > "$scratch/workshop/2222222222/scene.pkg"

# Oversized loose file -- 2 KB, exceeds the 1024-byte budget the run below
# sets, while the ~9-byte "good" files stay well under it.
head -c 2048 /dev/zero > "$scratch/workshop/1111111111/oversized.mdl"

# Loose files are named after the source inode (build-corpus.sh's loose-file
# loop uses `stat -c %i`), so the expected destination names must be computed
# from the fixtures, not assumed from their source basenames.
model_inode=$(stat -c %i "$scratch/workshop/1111111111/model.mdl")
image_inode=$(stat -c %i "$scratch/workshop/1111111111/image.tex")
oversized_inode=$(stat -c %i "$scratch/workshop/1111111111/oversized.mdl")

# Stub wp-pkg: handles only the one subcommand build-corpus.sh calls
# ("$wp_pkg" extract "$pkg" "$pkg_out"). Writes two files under budget (case
# 1) and one over budget (case 2's archive-side fixture), so the -size filter
# on the archive-extracted path gets exercised independently of the loose
# path.
cat > "$scratch/build/sub/tools/wp-pkg" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    extract)
        outdir="$3"
        mkdir -p "$outdir"
        printf 'archived-mdl-body' > "$outdir/archived.mdl"
        printf 'archived-tex-body' > "$outdir/archived.tex"
        head -c 2048 /dev/zero > "$outdir/archived_oversized.mdl"
        ;;
    *)
        echo "stub wp-pkg: unsupported subcommand $1" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$scratch/build/sub/tools/wp-pkg"

WP_WORKSHOP="$scratch/workshop" MAX_MDL_BYTES=1024 bash "$BUILD_CORPUS" "$scratch/build/sub" \
    >"$scratch/build-corpus.out" 2>&1

mdl_seed="$scratch/build/sub/corpus/WPMdlParser/seed"
tex_seed="$scratch/build/sub/corpus/WPTexImageParser/seed"
pkgfs_seed="$scratch/build/sub/corpus/WPPkgFs/seed"

# 1. All three passes land the files they're supposed to, under the exact
#    filenames each pass's own naming scheme produces. Checked directly
#    against the filesystem, not build-corpus.sh's own summary output, so a
#    bug in the summary line can't hide a real seeding failure.
ok1=1
[[ -f "$mdl_seed/$model_inode.mdl" ]]              || ok1=0   # loose .mdl landed
[[ -f "$tex_seed/$image_inode.tex" ]]              || ok1=0   # loose .tex landed
[[ -f "$mdl_seed/2222222222_archived.mdl" ]]       || ok1=0   # archive-extracted .mdl landed
[[ -f "$tex_seed/2222222222_archived.tex" ]]       || ok1=0   # archive-extracted .tex landed
[[ -f "$pkgfs_seed/2222222222.pkg" ]]              || ok1=0   # raw archive landed
cmp -s "$pkgfs_seed/2222222222.pkg" "$scratch/workshop/2222222222/scene.pkg" || ok1=0
[[ "$(find "$tex_seed" -type f | wc -l)" == "2" ]]    || ok1=0
[[ "$(find "$pkgfs_seed" -type f | wc -l)" == "1" ]]  || ok1=0

diag1="$(printf 'mdl_seed:\n%s\ntex_seed:\n%s\npkgfs_seed:\n%s\nbuild-corpus.sh output:\n%s\n' \
    "$(find "$mdl_seed" -type f 2>/dev/null)" "$(find "$tex_seed" -type f 2>/dev/null)" \
    "$(find "$pkgfs_seed" -type f 2>/dev/null)" "$(cat "$scratch/build-corpus.out")")"
report "build-corpus.sh seeds WPMdlParser, WPTexImageParser and WPPkgFs from a synthetic workshop dir with the exact filenames each pass produces" \
    "$ok1" "$diag1"

# 2. An oversized .mdl must be excluded on the loose-file path AND the
#    archive-extracted path independently -- a fix to one -size clause that
#    forgets its sibling four lines away would only fail one of these two.
ok2=1
[[ ! -e "$mdl_seed/$oversized_inode.mdl" ]]                  || ok2=0   # loose-side filter held
[[ ! -e "$mdl_seed/2222222222_archived_oversized.mdl" ]]     || ok2=0   # archive-side filter held
[[ "$(find "$mdl_seed" -type f | wc -l)" == "2" ]]           || ok2=0   # still exactly the 2 good files

diag2="$(printf 'mdl_seed contents:\n%s\n' "$(find "$mdl_seed" -type f 2>/dev/null)")"
report "an oversized .mdl is excluded independently on the loose-file path and the archive-extracted path" \
    "$ok2" "$diag2"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%s%d passed, %d failed%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
printf '%s%d passed%s\n' "$GREEN" "$PASS" "$RESET"
