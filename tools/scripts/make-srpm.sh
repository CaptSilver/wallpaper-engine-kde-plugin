#!/usr/bin/env bash
#
# Build a self-contained source RPM.
#
# Two choices here are not the obvious ones, both for reasons that bite:
#
#   * The tarball is packed from `git ls-files --recurse-submodules`, not from
#     `git archive`.  git archive still has no --recurse-submodules (checked on
#     2.55), so it emits an empty src/backend_scene — and that submodule has
#     seven of its own, one of them on gitlab.com.  The CMake install rules read
#     third_party/*/LICENSE directly, so a non-recursive tarball fails at
#     %install, not at link time.
#
#   * Version, Release and the changelog date are written into the spec as
#     literals before rpmbuild ever parses it.  The SRPM stores the spec
#     verbatim and mock re-parses it later on a builder with no git checkout and
#     a different clock, so anything left as %(...) gets re-evaluated in the
#     wrong place at the wrong time.
#
# Both .copr/Makefile and build-packages.sh call this, so a local RPM build
# exercises exactly the path COPR takes.

set -euo pipefail

NAME=wallpaper-engine-kde-plugin-qt6

outdir=""
spec=""

usage() {
    cat <<'USAGE'
usage: make-srpm.sh [--outdir DIR] [--spec PATH]

  --outdir DIR   where the .src.rpm and its tarball land
                 (default: <repo>/build/srpm)
  --spec PATH    spec template to stamp (default: <repo>/rpm/wek.spec)

COPR's make_srpm method invokes this via .copr/Makefile as:
  make -f .copr/Makefile srpm outdir="<dir>" spec="<path>"
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir) outdir="$2"; shift 2 ;;
        --spec)   spec="$2";   shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "make-srpm.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

: "${outdir:=$repo_root/build/srpm}"
: "${spec:=$repo_root/rpm/wek.spec}"
mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd)"

[[ -f "$spec" ]] || { echo "make-srpm.sh: no spec at $spec" >&2; exit 1; }

# COPR clones --depth 500 and can land without tags, which makes `git describe`
# die with "There are no tags in the repo".  The make_srpm step has network, so
# just refill them; failing that, the VERSION file carries the base version.
git fetch --tags --quiet 2>/dev/null || true

commit_epoch="$(git log -1 --format=%ct)"
commit_date="$(LC_ALL=C git log -1 --date=format:%Y%m%d --format=%cd)"
short="$(git rev-parse --short=7 HEAD)"

# rpm compares the changelog date, and a name it cannot parse makes it discard
# the WHOLE changelog and still exit 0.  Pin the locale.
changelog_date="$(LC_ALL=C git log -1 --date='format:%a %b %d %Y' --format=%cd)"

if tag="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
    # A release build: 1.5, not 1.5^something.
    version="${tag#v}"
    changelog_note="Release ${version}"
else
    base="$(tr -d '[:space:]' < VERSION)"
    if desc="$(git describe --tags --long --match 'v[0-9]*' HEAD 2>/dev/null)"; then
        rest="${desc%-g*}"        # v1.4-10-g5c9328e -> v1.4-10
        count="${rest##*-}"       #                  -> 10
    else
        count="$(git rev-list --count HEAD)"
    fi
    # The commit COUNT between date and hash is load-bearing.  The textbook
    # Fedora form 1.4^YYYYMMDDgit<hash> sorts same-day commits by hash, so about
    # half the time a newer commit compares LOWER and dnf calls it a downgrade.
    # '^' marks a post-release, so this sorts above 1.4 and below 1.5.
    version="${base}^${commit_date}.${count}.g${short}"
    changelog_note="Snapshot of ${short}, ${count} commit(s) past v${base}"
fi

# tar reads the working tree, not HEAD, so uncommitted edits land in the
# tarball under a version string that names a clean commit. COPR always builds
# a fresh clone and never trips this; say so out loud when building locally
# rather than shipping a package that misreports its own contents.
if [[ -n "$(git status --porcelain --ignore-submodules=none 2>/dev/null)" ]]; then
    version="${version}.dirty"
    changelog_note="${changelog_note} (uncommitted local changes)"
    echo "make-srpm.sh: working tree is dirty — tagging this build .dirty" >&2
fi

# --transform rewrites hard-link targets as well as member names, so a tracked
# symlink would come out of the tarball pointing somewhere new.  There are none
# today; fail loudly rather than ship a quietly broken archive if that changes.
if git ls-files -s --recurse-submodules | awk '$1 == "120000" { found = 1 } END { exit !found }'; then
    echo "make-srpm.sh: tracked symlinks found — --transform would rewrite their targets" >&2
    git ls-files -s --recurse-submodules | awk '$1 == "120000" { print "  " $4 }' >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> ${NAME}-${version}"

# The gitlink only records a SHA; a plain clone leaves the worktrees empty, and
# `git checkout <tag>` does not refresh them either.  Force it every time.
echo "==> fetching submodules (2 levels, 8 repos)"
git submodule update --init --force --recursive

echo "==> packing source tarball"
topdir="${NAME}-${version}"
tarball="${outdir}/${topdir}.tar.gz"
git ls-files -z --recurse-submodules \
    | tar --create --null --files-from=- \
          --transform="s,^,${topdir}/," \
          --owner=0 --group=0 --numeric-owner \
          --mtime="@${commit_epoch}" \
          --file="${work}/src.tar"
# -n drops the timestamp so the same commit always yields the same bytes.
gzip -n -9 < "${work}/src.tar" > "${tarball}"
printf '    %s (%s)\n' "$(basename "${tarball}")" "$(du -h "${tarball}" | cut -f1)"

echo "==> stamping spec"
stamped="${work}/${NAME}.spec"
sed -e "s|^Version:.*|Version: ${version}|" "${spec}" > "${stamped}"

# Prepend a resolved entry so the SRPM carries the built version's changelog.
awk -v date="${changelog_date}" -v ver="${version}" -v note="${changelog_note}" '
    { print }
    /^%changelog$/ && !done {
        printf "* %s packager - %s-1\n", date, ver
        printf "- %s\n\n", note
        done = 1
    }
' "${stamped}" > "${stamped}.new" && mv "${stamped}.new" "${stamped}"

echo "==> rpmbuild -bs"
rpmbuild -bs "${stamped}" \
    --define "_topdir ${work}/rpmbuild" \
    --define "_sourcedir ${outdir}" \
    --define "_srcrpmdir ${outdir}" \
    --define "_rpmdir ${work}/rpmbuild/RPMS"

srpm="$(ls -t "${outdir}/${NAME}"-*.src.rpm | head -1)"

# rpm does not fail the build when it rejects a changelog date — it drops every
# entry, sets CHANGELOGTIME to (none) and exits 0.  Catch that here.
ctime="$(rpm -qp --qf '%{CHANGELOGTIME}' "${srpm}" 2>/dev/null || true)"
if [[ -z "${ctime}" || "${ctime}" == "(none)" ]]; then
    echo "make-srpm.sh: ${srpm} has no changelog — rpm silently discarded it" >&2
    exit 1
fi

echo "==> ${srpm}"
