# Pass marker for the preflight gate: a record that the full gate passed for an
# exact tree, so the pre-push hook can skip re-running it on the same content.
#
# Sourced by preflight.sh (writes the marker) and git-hooks/pre-push (reads it).
# Everything works from the current directory, which must be the superproject
# root.  Nothing here touches the real index, refs or stash.
#
# The key is a pair of tree ids: the parent repo's and src/backend_scene's.  Both
# are taken from the WORKING tree through a throwaway index, because HEAD^{tree}
# does not move when a file is edited but not committed, and the parent tree only
# holds the submodule's gitlink, not its dirty files.  The gate's own scripts live
# in the parent tree, so editing one invalidates the marker with no extra hash.

GATE_SUB="${GATE_SUB:-src/backend_scene}"
GATE_MARKER_FILE="${GATE_MARKER_FILE:-build/.preflight-pass.json}"
GATE_MARKER_RING="${GATE_MARKER_RING:-5}"

# Tree id of <dir>'s working tree: tracked files as they are on disk plus
# untracked, non-ignored ones.  The throwaway index lives in the git dir so it
# never shows up in `git status`.
gate_tree_id() {
    local dir="$1" gd idx id
    gd="$(git -C "$dir" rev-parse --absolute-git-dir)" || return 1
    idx="$gd/gate-marker-index.$$"
    rm -f "$idx"
    id="$(
        export GIT_INDEX_FILE="$idx"
        trap 'rm -f "$idx"' EXIT      # an interrupted run must not strand the index
        cd "$dir" || exit 1
        git read-tree HEAD && git add -A && git write-tree
    )"
    local rc=$?
    rm -f "$idx"
    [[ $rc -eq 0 && -n "$id" ]] || return 1
    printf '%s' "$id"
}

# Prints "<parent-tree> <submodule-tree>" for the working tree.  A third_party
# checkout inside the submodule is invisible to both ids (only its gitlink is
# hashed), so a dirty one means no honest id exists.
gate_ids() {
    local p s="-"
    if [[ -e "$GATE_SUB/.git" ]]; then
        if [[ -n "$(git -C "$GATE_SUB" submodule foreach --recursive --quiet 'git status --porcelain' 2>/dev/null)" ]]; then
            echo "gate_ids: a nested submodule under $GATE_SUB has uncommitted changes" >&2
            return 1
        fi
        s="$(gate_tree_id "$GATE_SUB")" || return 1
    fi
    p="$(gate_tree_id .)" || return 1
    printf '%s %s' "$p" "$s"
}

# Prints "<parent-tree> <submodule-tree>" for <commit>.  Fails when the commit's
# submodule revision is not present locally: it cannot be compared, so the caller
# must run the gate.
gate_commit_ids() {
    local commit="$1" p s="-" link
    p="$(git rev-parse --verify --quiet "$commit^{tree}")" || return 1
    link="$(git ls-tree "$commit" -- "$GATE_SUB" | awk '$1 == "160000" {print $3}')"
    if [[ -n "$link" ]]; then
        s="$(git -C "$GATE_SUB" rev-parse --verify --quiet "$link^{tree}")" || return 1
    fi
    printf '%s %s' "$p" "$s"
}

# gate_marker_should_write MODE NO_FUZZ FUZZ_DEGRADED MUTATION_RC
# Only a complete default run earns a marker: a --no-fuzz or short fuzz run, a
# mutation leg that measured nothing (78) or was skipped past the diff cap (79),
# or one that reported survivors would otherwise be laundered into a pass.  77 is
# fine: the same skip would repeat in the same environment.
gate_marker_should_write() {
    local mode="$1" no_fuzz="$2" fuzz_degraded="$3" mrc="$4"
    [[ "$mode" == "full" && "$no_fuzz" == "0" && "$fuzz_degraded" == "0" ]] || return 1
    [[ "$mrc" == "0" || "$mrc" == "77" ]]
}

# gate_coverage_strictness
# 1 when the coverage leg runs and can fail the gate.  COVERAGE_FATAL=0 turns the
# leg advisory, and an advisory pass must not stand in for a fatal one.
gate_coverage_strictness() {
    if [[ "${WEK_COVERAGE_IN_GATE:-0}" == "1" && "${COVERAGE_FATAL:-1}" != "0" ]]; then
        echo 1
    else
        echo 0
    fi
}

# gate_marker_write <parent-tree> <submodule-tree>
# Records the ids with the strictness this run enforced, keeping the last few
# entries so alternating between branches still hits.  Written atomically.
gate_marker_write() {
    local p="$1" s="$2" tmp
    mkdir -p "$(dirname "$GATE_MARKER_FILE")"
    tmp="$GATE_MARKER_FILE.tmp.$$"
    python3 - "$GATE_MARKER_FILE" "$GATE_MARKER_RING" "$p" "$s" \
        "${MUTATION_FATAL:-0}" "$(gate_coverage_strictness)" "${FUZZ_SECS:-20}" > "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import json, sys, time
path, ring, p, s, mfatal, cov, fuzz = sys.argv[1:8]
try:
    entries = json.load(open(path)).get("entries", [])
except (OSError, ValueError):
    entries = []
entries = [e for e in entries if (e.get("parent_tree"), e.get("sub_tree")) != (p, s)]
entries.append({"parent_tree": p, "sub_tree": s, "time": int(time.time()),
                "mutation_fatal": int(mfatal), "coverage_in_gate": int(cov),
                "fuzz_secs": int(fuzz)})
print(json.dumps({"entries": entries[-int(ring):]}, indent=1))
PY
    mv -f "$tmp" "$GATE_MARKER_FILE"
}

# gate_marker_matches <commit>
# True when the marker holds an entry for <commit>'s tree pair that is young
# enough (WEK_GATE_MAX_AGE_H, default 24: a toolchain update is not in the key)
# and at least as strict as the current environment.  On success sets
# GATE_MATCH_TREE (short parent tree) and GATE_MATCH_AGE (human readable).
gate_marker_matches() {
    local commit="$1" ids p s out
    [[ -f "$GATE_MARKER_FILE" ]] || return 1
    ids="$(gate_commit_ids "$commit")" || return 1
    read -r p s <<<"$ids"
    out="$(python3 - "$GATE_MARKER_FILE" "$p" "$s" "${WEK_GATE_MAX_AGE_H:-24}" \
        "${MUTATION_FATAL:-0}" "$(gate_coverage_strictness)" <<'PY'
import json, sys, time
path, p, s, max_h, mfatal, cov = sys.argv[1:7]
try:
    entries = json.load(open(path)).get("entries", [])
except (OSError, ValueError):
    sys.exit(1)
now = time.time()
for e in reversed(entries):
    if (e.get("parent_tree"), e.get("sub_tree")) != (p, s):
        continue
    age = now - e.get("time", 0)
    if age > float(max_h) * 3600:
        continue
    if int(mfatal) > e.get("mutation_fatal", 0) or int(cov) > e.get("coverage_in_gate", 0):
        continue
    age = int(age)
    if age >= 3600:
        human = f"{age // 3600}h ago"
    elif age >= 60:
        human = f"{age // 60}m ago"
    else:
        human = f"{age}s ago"
    print(human)
    sys.exit(0)
sys.exit(1)
PY
    )" || return 1
    GATE_MATCH_TREE="${p:0:10}"
    GATE_MATCH_AGE="$out"
}
