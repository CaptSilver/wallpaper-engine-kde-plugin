#!/usr/bin/env bash
# Test harness for scripts/migrate-from-catsout.sh.
# Each test creates a temp HOME dir, copies a fixture appletsrc into it,
# runs the script (with HOME / XDG_CONFIG_HOME pointing at the temp dir),
# and diffs the result against the expected appletsrc.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/migrate-from-catsout.sh"
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
    HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
        PATH="$sandbox/bin:$PATH" "$SCRIPT" --auto >/dev/null 2>&1 || {
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

# ── tests ─────────────────────────────────────────────────────────────────────
run_test appletsrc-already-migrated 0 appletsrc-already-migrated.expected 0 0 0
run_test appletsrc-simple           0 appletsrc-simple.expected   1 1 1
run_test appletsrc-multidesk        0 appletsrc-multidesk.expected 1 0 1
run_idempotency_test appletsrc-simple
run_concurrent_test
run_dryrun_test

echo
echo "Tests: $PASS passed, $FAIL failed."
exit $FAIL
