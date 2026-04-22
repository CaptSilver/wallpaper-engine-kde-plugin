#!/usr/bin/env bash
# Regenerates debian/changelog by prepending a snapshot stanza to debian/changelog.in.
#
# Run this before dpkg-buildpackage so the built .deb is versioned against the
# current git HEAD rather than the last released tag. Idempotent: each run
# rewrites debian/changelog from scratch using the tracked debian/changelog.in
# base plus a fresh snapshot stanza (today's date, current HEAD short-SHA).
#
# Snapshot package version: <top .in version> + "+git." + <short-sha>
# (e.g. "1.2+git.abc1234"). The .in file's historical stanzas are preserved
# verbatim below the snapshot stanza.

set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
in_file="$repo_root/debian/changelog.in"
out_file="$repo_root/debian/changelog"

if [[ ! -f "$in_file" ]]; then
    echo "error: $in_file not found" >&2
    exit 1
fi

first_line="$(head -n1 "$in_file")"
pkg_name="${first_line%% *}"
rest="${first_line#*\(}"
top_version="${rest%%\)*}"

if [[ -z "$pkg_name" || -z "$top_version" ]]; then
    echo "error: could not parse package name / version from $in_file first line: $first_line" >&2
    exit 1
fi

short_sha="$(git -C "$repo_root" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
date_rfc="$(date -R)"
snapshot_version="${top_version}+git.${short_sha}"

{
    printf '%s (%s) unstable; urgency=medium\n\n' "$pkg_name" "$snapshot_version"
    printf '  * Snapshot build from commit %s.\n\n' "$short_sha"
    printf ' -- packager <noreply@localhost>  %s\n\n' "$date_rfc"
    cat "$in_file"
} > "$out_file"

echo "Wrote $out_file ($snapshot_version)"
