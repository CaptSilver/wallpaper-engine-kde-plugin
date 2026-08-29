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
#     wrong place at the wrong time.  %{?dist} is the deliberate exception --
#     it names the chroot, so only the builder can expand it.
#
# Both .copr/Makefile and build-packages.sh call this, so a local RPM build
# exercises exactly the path COPR takes.

set -euo pipefail

NAME=wallpaper-engine-kde-plugin-qt6

outdir=""
spec=""
release=1
allow_skew=0

usage() {
    cat <<'USAGE'
usage: make-srpm.sh [--outdir DIR] [--spec PATH] [--release N] [--allow-skew]

  --outdir DIR   where the .src.rpm and its tarball land
                 (default: <repo>/build/srpm)
  --spec PATH    spec template to stamp (default: <repo>/rpm/wek.spec)
  --release N    release serial (default 1).  Bump it to republish the SAME
                 commit -- after a soname bump in the build chroot, say.  Leave
                 it alone and the rebuild carries an EVR identical to the build
                 before it, which dnf reads as "already have that" and skips.
  --allow-skew   build even though an ancestor of HEAD carries a later committer
                 date than HEAD.  The escape hatch for a bad clock buried in
                 history; the build it produces may sort below a published one.

COPR's make_srpm method invokes this via .copr/Makefile as:
  make -f .copr/Makefile srpm outdir="<dir>" spec="<path>"
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir) outdir="$2"; shift 2 ;;
        --spec)   spec="$2";   shift 2 ;;
        --release) release="$2"; shift 2 ;;
        --allow-skew) allow_skew=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "make-srpm.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$release" =~ ^[1-9][0-9]*$ ]] \
    || { echo "make-srpm.sh: --release must be a positive integer, got '$release'" >&2; exit 2; }

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
    if [[ -z "$base" ]]; then
        echo "make-srpm.sh: VERSION is empty -- refusing to build ${NAME}-^${commit_date}" >&2
        exit 1
    fi

    # VERSION and a release tag are two independent sources for the same number
    # and nothing keeps them in step.  Cut v1.5 without moving VERSION and every
    # snapshot after it still says 1.4^... -- which sorts BELOW the published
    # 1.5, so dnf pins everyone to the release and offers no snapshot ever
    # again.  Tag and bump VERSION in the same commit.
    #
    # VERSION EQUAL to the tag is the healthy state, not a fault: the tagged
    # commit built as the plain version, and rpm sorts 1.4^stamp ABOVE 1.4, so
    # the next snapshot lands just above the release exactly as intended.  Only
    # a VERSION below the newest tag is broken.
    last_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    if [[ -n "$last_tag" ]]; then
        tag_v="${last_tag#v}"
        oldest="$(printf '%s\n%s\n' "$base" "$tag_v" | sort -V | head -1)"
        if [[ "$base" != "$tag_v" && "$oldest" == "$base" ]]; then
            echo "make-srpm.sh: VERSION ($base) is behind tag ${last_tag}." >&2
            echo "make-srpm.sh: ${base}^${commit_date} would sort below the published ${tag_v}," >&2
            echo "make-srpm.sh: so nobody on ${tag_v} would ever be offered it." >&2
            echo "make-srpm.sh: bump VERSION to ${tag_v} or later." >&2
            exit 1
        fi
    fi

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

# The whole scheme rests on HEAD being the newest commit on the branch by
# committer date.  A skewed clock or an explicit --date breaks that, and the
# damage is silent and permanent: the date segment is compared before the count,
# so a build from a later commit sorts BELOW one already published and dnf reads
# the upgrade as a downgrade from then on.
newest="$(git log -500 --format=%ct | awk 'NR == 1 || $1 > m { m = $1 } END { print m + 0 }')"
if [[ "$newest" -gt "$commit_epoch" ]]; then
    echo "make-srpm.sh: an ancestor of HEAD is dated $((newest - commit_epoch))s later than HEAD." >&2
    echo "make-srpm.sh: ${version} would sort below anything built from that commit." >&2
    if [[ "$allow_skew" -eq 0 ]]; then
        echo "make-srpm.sh: commit again to carry HEAD's date past it, or pass --allow-skew." >&2
        exit 1
    fi
    echo "make-srpm.sh: --allow-skew given, publishing it anyway." >&2
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
sed -e "s|^Version:.*|Version: ${version}|" \
    -e "s|^Release:.*|Release: ${release}%{?dist}|" \
    "${spec}" > "${stamped}"

# Prepend a resolved entry so the SRPM carries the built version's changelog.
# Prepending rather than replacing is deliberate -- the entries already in the
# spec are the curated release history and belong in the package.  The cost is
# that building a commit older than the newest entry puts the changelog out of
# order, which rpm answers by discarding from the offender down.  The check
# after rpmbuild below is what turns that into a failure instead of a surprise.
awk -v date="${changelog_date}" -v ver="${version}" -v rel="${release}" -v note="${changelog_note}" '
    { print }
    /^%changelog$/ && !done {
        printf "* %s packager - %s-%s\n", date, ver, rel
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

# Match on the version just built rather than "newest file here" -- a reused
# outdir holds older builds, and picking one of those would report success for a
# package that was never produced.
shopt -s nullglob
srpms=("${outdir}/${topdir}"-*.src.rpm)
shopt -u nullglob
if [[ "${#srpms[@]}" -ne 1 ]]; then
    echo "make-srpm.sh: expected one ${topdir}-*.src.rpm in ${outdir}, found ${#srpms[@]}" >&2
    [[ "${#srpms[@]}" -eq 0 ]] || printf '  %s\n' "${srpms[@]}" >&2
    exit 1
fi
srpm="${srpms[0]}"

# rpm never fails a build over a changelog it dislikes; it drops entries and
# exits 0.  A date it cannot parse costs you the whole thing, an out-of-order one
# costs you everything from the offender down -- and that second case leaves
# CHANGELOGTIME populated, so asking merely whether a changelog exists sails
# straight past it.  Assert the entry just generated is the one that survived.
if ! rpm -qp --qf '%{CHANGELOGNAME}\n' "${srpm}" 2>/dev/null \
        | grep -qF -- "${version}-${release}"; then
    echo "make-srpm.sh: ${srpm} carries no changelog entry for ${version}-${release}" >&2
    echo "make-srpm.sh: rpm discarded it -- suspect a bad or out-of-order date" >&2
    rpm -qp --changelog "${srpm}" >&2 || true
    exit 1
fi

echo "==> ${srpm}"
