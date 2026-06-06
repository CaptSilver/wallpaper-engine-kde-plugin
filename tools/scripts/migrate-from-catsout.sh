#!/usr/bin/env bash
# wek-migrate-from-catsout — migrate plasma containment config from
# com.github.catsout.wallpaperEngineKde to com.github.captsilver.wallpaperEngineKde.
#
# Usage: wek-migrate-from-catsout [--auto] [--dry-run] [--verbose]
set -euo pipefail

SCRIPT_VERSION="0.1.0"
AUTO=0
DRY_RUN=0
VERBOSE=0

while (($#)); do
    case "$1" in
        --auto)    AUTO=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h)
            sed -n '2,7p' "$0"
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
    shift
done

# Allow tests to override the user config dir.
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

log() { (( VERBOSE )) && echo "[migrate] $*" >&2 || true; }
fail() { echo "[migrate] error: $*" >&2; exit "${2:-1}"; }

# ── concurrent dedup ─────────────────────────────────────────────────────────
# Plasma instantiates main.qml once per containment, so on multi-desktop setups
# the auto-fallback may invoke this script multiple times in quick succession.
# flock() on a per-UID lockfile ensures only one runs; the rest exit silently.
LOCKFILE="${TMPDIR:-/tmp}/wek-migrate-${UID:-$(id -u)}.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "another instance is already running ($LOCKFILE held)"
    exit 0
fi
trap 'flock -u 9 2>/dev/null || true; rm -f "$LOCKFILE"' EXIT

# ── plasmashell control ──────────────────────────────────────────────────────
plasmashell_pid() { pgrep -u "${UID:-$(id -u)}" -x plasmashell || true; }

stop_plasmashell() {
    if (( DRY_RUN )); then
        log "would stop plasmashell"
        return 0
    fi
    if systemctl --user list-unit-files plasma-plasmashell.service \
       >/dev/null 2>&1; then
        systemctl --user stop plasma-plasmashell.service \
            >/dev/null 2>&1 || true
    elif command -v kquitapp6 >/dev/null 2>&1; then
        kquitapp6 plasmashell >/dev/null 2>&1 || true
    fi
    # Wait up to 10s for the process to actually exit.
    local i=0
    while (( i < 100 )); do
        [[ -z "$(plasmashell_pid)" ]] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 3
}

start_plasmashell() {
    if (( DRY_RUN )); then
        log "would start plasmashell"
        return 0
    fi
    if systemctl --user list-unit-files plasma-plasmashell.service \
       >/dev/null 2>&1; then
        systemctl --user start plasma-plasmashell.service \
            >/dev/null 2>&1 || true
    else
        setsid plasmashell >/dev/null 2>&1 &
    fi
}

# ── pre-flight ───────────────────────────────────────────────────────────────
(( EUID == 0 )) && fail "do not run as root — migration is per-user" 1

OLD_URI="com.github.catsout.wallpaperEngineKde"
NEW_URI="com.github.captsilver.wallpaperEngineKde"
APPLETSRC_GLOB="$CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"
MARKER="$CONFIG_HOME/wekde/migrated-from-catsout"

# Work detection: stop early if there's nothing to migrate.
detect_work() {
    # 1. Any appletsrc-style file mentioning the catsout URI?
    for f in "$APPLETSRC_GLOB"*; do
        [[ -f "$f" ]] || continue
        if grep -qF "$OLD_URI" "$f" 2>/dev/null; then
            return 0
        fi
    done
    # 2. Catsout install dir present?
    [[ -d "$HOME/.local/share/plasma/wallpapers/$OLD_URI" ]] && return 0
    # 3. kpackagetool6 lists the catsout package?
    if command -v kpackagetool6 >/dev/null 2>&1; then
        if kpackagetool6 -t Plasma/Wallpaper -l 2>/dev/null \
           | grep -qF "$OLD_URI"; then
            return 0
        fi
    fi
    return 1
}

if ! detect_work; then
    log "no migration needed"
    exit 0
fi

# Marker already present → migration ran before. Don't re-run unless the user
# explicitly asked (interactive non-auto invocation).
if [[ -f "$MARKER" && "$AUTO" -eq 1 ]]; then
    log "marker present — already migrated"
    exit 0
fi

# Auto mode: brief delay so plasmashell can flush any pending KConfig writes
# from our just-loaded plugin before we kill it.
(( AUTO )) && sleep 0.5

stop_plasmashell || fail "plasmashell would not stop within 10s — aborted before any edits" 3

# ── backup ───────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
BACKUP_DIR="$CONFIG_HOME/wek-migration-backup/$TIMESTAMP"
if (( DRY_RUN )); then
    log "would create backup at: $BACKUP_DIR"
else
    mkdir -p "$BACKUP_DIR" || fail "cannot create backup dir $BACKUP_DIR" 2
    for f in "$APPLETSRC_GLOB"* "$CONFIG_HOME/kscreenlockerrc"; do
        [[ -f "$f" ]] || continue
        cp -a "$f" "$BACKUP_DIR/" || fail "backup of $f failed" 2
    done
    log "backup at $BACKUP_DIR"
fi

# ── rewrite appletsrc files ──────────────────────────────────────────────────
rewrite_file() {
    local src=$1
    local dst="$src.tmp.$$"
    sed "s|${OLD_URI}|${NEW_URI}|g" "$src" > "$dst" || {
        rm -f "$dst"
        return 1
    }
    if (( DRY_RUN )); then
        log "would rewrite: $src"
        rm -f "$dst"
    else
        mv -f "$dst" "$src" || return 1
    fi
}

REWRITE_COUNT=0
for f in "$APPLETSRC_GLOB"* "$CONFIG_HOME/kscreenlockerrc"; do
    [[ -f "$f" ]] || continue
    if grep -qF "$OLD_URI" "$f" 2>/dev/null; then
        rewrite_file "$f" || fail "rewrite of $f failed" 4
        REWRITE_COUNT=$((REWRITE_COUNT + 1))
    fi
done
log "rewrote $REWRITE_COUNT file(s)"

# ── remove old plugin install ────────────────────────────────────────────────
OLD_PKG_DIR="$HOME/.local/share/plasma/wallpapers/$OLD_URI"
if (( DRY_RUN )); then
    [[ -d "$OLD_PKG_DIR" ]] && log "would rm -rf $OLD_PKG_DIR"
    log "would kpackagetool6 -r $OLD_URI"
else
    if command -v kpackagetool6 >/dev/null 2>&1; then
        if kpackagetool6 -t Plasma/Wallpaper -l 2>/dev/null \
           | grep -qF "$OLD_URI"; then
            kpackagetool6 -t Plasma/Wallpaper -r "$OLD_URI" \
                >/dev/null 2>&1 || log "kpackagetool6 -r failed (non-fatal)"
        fi
    fi
    [[ -d "$OLD_PKG_DIR" ]] && rm -rf "$OLD_PKG_DIR"
fi

# ── write completion marker ──────────────────────────────────────────────────
mkdir -p "$CONFIG_HOME/wekde"
if (( DRY_RUN )); then
    log "would write marker $MARKER"
else
    cat > "$MARKER" <<EOF
timestamp=$(date -Iseconds)
script_version=$SCRIPT_VERSION
files_modified=$REWRITE_COUNT
backup=$BACKUP_DIR
EOF
    log "marker written: $MARKER"
fi

start_plasmashell

log "migration complete"
exit 0
