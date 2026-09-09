#!/usr/bin/env bash
# Test harness for tools/scripts/migrate-from-catsout.sh.
# Each test creates a temp HOME dir, copies a fixture appletsrc into it,
# runs the script (with HOME / XDG_CONFIG_HOME pointing at the temp dir),
# and diffs the result against the expected appletsrc.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/scripts/migrate-from-catsout.sh"
FIXTURES="$REPO_ROOT/tests/scripts/fixtures"

PASS=0
FAIL=0

# Create a sandboxed HOME with fake plasma binaries on PATH.
make_sandbox() {
    local sandbox=$1
    mkdir -p "$sandbox/.config" "$sandbox/bin" \
             "$sandbox/.local/share/plasma/wallpapers"
    # Fake plasmashell — accepts --version, ignores SIGTERM gracefully.
    cat > "$sandbox/bin/plasmashell" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "plasmashell 6.0.0 (test fake)" ;;
    *) trap 'exit 0' TERM; sleep 30 ;;
esac
EOF
    chmod +x "$sandbox/bin/plasmashell"
    # Fake systemctl — silently succeeds.
    cat > "$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$sandbox/bin/systemctl"
    # Fake kpackagetool6 — reports the catsout package as not installed.
    cat > "$sandbox/bin/kpackagetool6" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
    -l) echo "" ;;
    *)  exit 0 ;;
esac
EOF
    chmod +x "$sandbox/bin/kpackagetool6"
    # Fake pgrep — never finds plasmashell, so stop_plasmashell short-circuits.
    # (Real pgrep would find the user's actual running plasmashell, breaking the
    # work loop. We override by name; full PATH-prepend in run_test ensures this
    # version wins.)
    cat > "$sandbox/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$sandbox/bin/pgrep"
}

seed_old_install() {
    local sandbox=$1
    mkdir -p "$sandbox/.local/share/plasma/wallpapers/com.github.catsout.wallpaperEngineKde/contents"
    echo '{"KPlugin":{"Id":"com.github.catsout.wallpaperEngineKde"}}' \
        > "$sandbox/.local/share/plasma/wallpapers/com.github.catsout.wallpaperEngineKde/metadata.json"
}

assert_backup_present() {
    local sandbox=$1
    ls "$sandbox/.config/wek-migration-backup/"*/plasma-org.kde.plasma.desktop-appletsrc \
        >/dev/null 2>&1
}

assert_marker_present() {
    local sandbox=$1
    [[ -f "$sandbox/.config/wekde/migrated-from-catsout" ]]
}

# The plugin's in-process migration writes this same file, so a marker in a
# fresh sandbox stands in for "migration already happened".
write_marker() {
    local sandbox=$1
    mkdir -p "$sandbox/.config/wekde"
    echo ok > "$sandbox/.config/wekde/migrated-from-catsout"
}

# run_test <name> <expect_exit> <expect_out> [assert_backup=0|1] [seed_old=0|1] [expect_marker=0|1]
run_test() {
    local name=$1 expect_exit=$2 expect_out=${3:-} assert_backup=${4:-0} \
          seed_old=${5:-0} expect_marker=${6:-0}
    local sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    (( seed_old )) && seed_old_install "$sandbox"
    cp "$FIXTURES/$name.in" "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    local actual_exit=0
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" \
        "$SCRIPT" --auto --verbose 2>/dev/null || actual_exit=$?
    if [[ "$actual_exit" -ne "$expect_exit" ]]; then
        echo "FAIL [$name]: exit code $actual_exit, expected $expect_exit"
        FAIL=$((FAIL + 1))
        rm -rf "$sandbox"
        return
    fi
    if [[ -n "$expect_out" ]]; then
        if ! diff -u "$FIXTURES/$expect_out" \
                "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"; then
            echo "FAIL [$name]: appletsrc differs from expected"
            FAIL=$((FAIL + 1))
            rm -rf "$sandbox"
            return
        fi
    fi
    if (( assert_backup )); then
        if ! assert_backup_present "$sandbox"; then
            echo "FAIL [$name]: backup not created"
            FAIL=$((FAIL + 1))
            rm -rf "$sandbox"
            return
        fi
    fi
    if (( seed_old )); then
        if [[ -d "$sandbox/.local/share/plasma/wallpapers/com.github.catsout.wallpaperEngineKde" ]]; then
            echo "FAIL [$name]: old install dir not removed"
            FAIL=$((FAIL + 1))
            rm -rf "$sandbox"
            return
        fi
    fi
    if (( expect_marker )); then
        if ! assert_marker_present "$sandbox"; then
            echo "FAIL [$name]: marker not written"
            FAIL=$((FAIL + 1))
            rm -rf "$sandbox"
            return
        fi
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

run_idempotency_test() {
    local name="idempotency-$1" sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/$1.in" "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --auto >/dev/null 2>&1 || {
        echo "FAIL [$name]: first run failed"; FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    }
    # --force: the first run leaves a marker, and without the override the
    # second run would stop at it and prove nothing about the rewrite.
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --auto --force >/dev/null 2>&1 || {
        echo "FAIL [$name]: second run failed"; FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    }
    if ! diff -q "$FIXTURES/$1.expected" \
            "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc" >/dev/null; then
        echo "FAIL [$name]: appletsrc differs after idempotent re-run"
        FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

run_concurrent_test() {
    local sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-simple.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    local pids=()
    for i in 1 2 3 4 5; do
        HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
            PATH="$sandbox/bin:$PATH" "$SCRIPT" --auto >/dev/null 2>&1 &
        pids+=("$!")
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    if ! diff -q "$FIXTURES/appletsrc-simple.expected" \
            "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc" >/dev/null; then
        echo "FAIL [concurrent]: appletsrc differs"
        FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    fi
    local backup_count
    backup_count=$(ls -d "$sandbox/.config/wek-migration-backup/"*/ 2>/dev/null | wc -l)
    if (( backup_count != 1 )); then
        echo "FAIL [concurrent]: expected 1 backup dir, got $backup_count"
        FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    fi
    echo "PASS [concurrent]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

run_dryrun_test() {
    local name="dry-run" sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-simple.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --dry-run --verbose >/dev/null 2>&1
    if ! diff -q "$FIXTURES/appletsrc-simple.in" \
            "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc" >/dev/null; then
        echo "FAIL [$name]: --dry-run modified appletsrc"
        FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    fi
    if [[ -f "$sandbox/.config/wekde/migrated-from-catsout" ]]; then
        echo "FAIL [$name]: --dry-run wrote marker"
        FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

# A marker means the migration already ran — through this script or through the
# plugin's in-process path. An interactive run must stop there just like --auto
# does, without touching config and without bouncing plasmashell.
run_marker_test() {
    local name="marker-stops-interactive-run" sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-post-inprocess.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    write_marker "$sandbox"
    local actual_exit=0
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --verbose >/dev/null 2>&1 || actual_exit=$?
    if [[ "$actual_exit" -ne 0 ]]; then
        echo "FAIL [$name]: exit code $actual_exit, expected 0"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    if ! diff -u "$FIXTURES/appletsrc-post-inprocess.in" \
            "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"; then
        echo "FAIL [$name]: appletsrc rewritten despite the marker"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    if [[ -d "$sandbox/.config/wek-migration-backup" ]]; then
        echo "FAIL [$name]: ran far enough to take a backup"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

# --force is the way past the marker. It must produce the merge result, not the
# duplicate-group mess a blind rename would leave behind.
run_force_test() {
    local name="force-overrides-marker" sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-post-inprocess.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    write_marker "$sandbox"
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --force >/dev/null 2>&1 || {
        echo "FAIL [$name]: forced run failed"; FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    }
    if ! diff -u "$FIXTURES/appletsrc-post-inprocess.expected" \
            "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"; then
        echo "FAIL [$name]: appletsrc differs from expected"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

# Containment already carrying a captsilver group: the catsout group donates
# only the keys the captsilver one lacks and keeps its own name, so the file
# never ends up with two groups under the same header.
run_merge_test() {
    local name="merge-keeps-single-captsilver-group" sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-post-inprocess.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --auto >/dev/null 2>&1 || {
        echo "FAIL [$name]: run failed"; FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    }
    local result="$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if ! diff -u "$FIXTURES/appletsrc-post-inprocess.expected" "$result"; then
        echo "FAIL [$name]: appletsrc differs from expected"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    local dupes
    dupes=$(grep -cFx \
        "[Containments][1][Wallpaper][com.github.captsilver.wallpaperEngineKde][General]" \
        "$result")
    if (( dupes != 1 )); then
        echo "FAIL [$name]: $dupes captsilver General headers in containment 1, expected 1"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

# The lockscreen wallpaper lives in kscreenlockerrc, and it can be the only
# place catsout is still named — appletsrc alone is not enough to decide there
# is no work to do.
run_locker_test() {
    local name="lockscreen-only-reference" sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-already-migrated.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"
    cp "$FIXTURES/kscreenlockerrc-post-inprocess.in" "$sandbox/.config/kscreenlockerrc"
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --auto >/dev/null 2>&1 || {
        echo "FAIL [$name]: run failed"; FAIL=$((FAIL + 1))
        rm -rf "$sandbox"; return
    }
    if ! diff -u "$FIXTURES/kscreenlockerrc-post-inprocess.expected" \
            "$sandbox/.config/kscreenlockerrc"; then
        echo "FAIL [$name]: kscreenlockerrc differs from expected"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}

# ── tests ─────────────────────────────────────────────────────────────────────
run_test appletsrc-already-migrated 0 appletsrc-already-migrated.expected 0 0 0
run_test appletsrc-simple           0 appletsrc-simple.expected   1 1 1
run_test appletsrc-multidesk        0 appletsrc-multidesk.expected 1 0 1
run_idempotency_test appletsrc-simple
# The migration must refuse a config home owned by someone else — that is the
# `sudo -E` case, where root would rewrite the user's files and leave
# root-owned backups behind.  Needs privilege to hand a directory to another
# uid, so it only runs where we have it; say so out loud when we don't, rather
# than passing silently.
run_foreign_owner_test() {
    local name="foreign-owned-config-home"
    local sandbox; sandbox=$(mktemp -d)
    make_sandbox "$sandbox"
    cp "$FIXTURES/appletsrc-simple.in" \
       "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc"

    if ! chown -R 65534 "$sandbox/.config" 2>/dev/null; then
        echo "SKIP [$name]: cannot chown to another uid as uid $EUID"
        rm -rf "$sandbox"
        return
    fi

    local out actual_exit=0
    out=$(HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
          PATH="$sandbox/bin:$PATH" \
          "$SCRIPT" --auto --verbose 2>&1) || actual_exit=$?

    if [[ "$actual_exit" -ne 1 ]]; then
        echo "FAIL [$name]: exit code $actual_exit, expected 1"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    if ! grep -qiE 'owned by|not the owner' <<<"$out"; then
        echo "FAIL [$name]: refused, but not for ownership: $out"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    if ! diff -q "$FIXTURES/appletsrc-simple.in" \
         "$sandbox/.config/plasma-org.kde.plasma.desktop-appletsrc" >/dev/null; then
        echo "FAIL [$name]: refused but still edited appletsrc"
        FAIL=$((FAIL + 1)); rm -rf "$sandbox"; return
    fi
    echo "PASS [$name]"
    PASS=$((PASS + 1))
    rm -rf "$sandbox"
}


run_idempotency_test appletsrc-post-inprocess
run_concurrent_test
run_dryrun_test
run_marker_test
run_force_test
run_merge_test
run_locker_test
run_foreign_owner_test

echo
echo "Tests: $PASS passed, $FAIL failed."
exit $FAIL
