#!/usr/bin/env bash
# wek-migrate-from-catsout — migrate plasma containment config from
# com.github.catsout.wallpaperEngineKde to com.github.captsilver.wallpaperEngineKde.
#
# The plugin migrates in-process on its first start (src/MigrationHelper.cpp);
# this script is the manual/CLI route for people who need to drive it by hand.
# Both write the same completion marker and each stops when it finds it.
set -euo pipefail

SCRIPT_VERSION="0.1.0"
AUTO=0
DRY_RUN=0
VERBOSE=0
FORCE=0

usage() {
    cat <<'USAGE'
Usage: wek-migrate-from-catsout [--auto] [--dry-run] [--force] [--verbose]

Migrates plasma containment config from com.github.catsout.wallpaperEngineKde
to com.github.captsilver.wallpaperEngineKde.

  --auto      called from the plugin's fallback path: stay quiet, give
              plasmashell a moment to flush pending config writes first
  --dry-run   report what would change, touch nothing
  --force     run even though the completion marker says migration is done
  --verbose   trace progress on stderr
USAGE
}

while (($#)); do
    case "$1" in
        --auto)    AUTO=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 64 ;;
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
# Owning the config home is the real precondition, not "don't be root".  The
# case worth refusing is `sudo -E`, which keeps the caller's HOME: root then
# rewrites the user's files and leaves root-owned backups in their home for
# plasmashell to trip over later.  Root operating on root's own config is
# harmless, and a container has no other kind of user.  Checking ownership
# also catches a plain user pointed at someone else's config home, which the
# root test never covered.
config_home_owner() {
    local d="$CONFIG_HOME"
    while [[ ! -e "$d" && "$d" != "/" ]]; do d=$(dirname "$d"); done
    stat -c %u "$d" 2>/dev/null
}
CONFIG_OWNER=$(config_home_owner) \
    || fail "cannot determine the owner of $CONFIG_HOME" 1
[[ -n "$CONFIG_OWNER" ]] \
    || fail "cannot determine the owner of $CONFIG_HOME" 1
(( CONFIG_OWNER == EUID )) \
    || fail "$CONFIG_HOME is owned by uid $CONFIG_OWNER, not $EUID — run the migration as that user" 1

OLD_URI="com.github.catsout.wallpaperEngineKde"
NEW_URI="com.github.captsilver.wallpaperEngineKde"
APPLETSRC_GLOB="$CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"
MARKER="$CONFIG_HOME/wekde/migrated-from-catsout"

# Every config file the migration reads or rewrites: the appletsrc family (one
# file per activity / screen split) and the lockscreen config. One list, so
# work detection can never disagree with what the rewrite loop then touches.
config_files() {
    local f
    for f in "$APPLETSRC_GLOB"* "$CONFIG_HOME/kscreenlockerrc"; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

# Work detection: stop early if there's nothing to migrate.
detect_work() {
    local f
    # 1. Any config file mentioning the catsout URI? A lockscreen wallpaper can
    #    be the only thing left on the old plugin.
    while IFS= read -r f; do
        if grep -qF "$OLD_URI" "$f" 2>/dev/null; then
            return 0
        fi
    done < <(config_files)
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

# Marker present → migration already ran, here or in-process in the plugin.
# Stop regardless of how we were invoked: a second pass has nothing left to
# move and costs the user a plasmashell restart. --force is the way past it.
if [[ -f "$MARKER" && "$FORCE" -eq 0 ]]; then
    log "marker present — already migrated"
    (( AUTO )) || echo "[migrate] already migrated ($MARKER) — pass --force to run anyway" >&2
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
    while IFS= read -r f; do
        cp -a "$f" "$BACKUP_DIR/" || fail "backup of $f failed" 2
    done < <(config_files)
    log "backup at $BACKUP_DIR"
fi

# ── rewrite appletsrc files ──────────────────────────────────────────────────
# Rename catsout-named groups to the captsilver name, EXCEPT where that name is
# already taken in the same [Wallpaper] subtree — the in-process migration copies the
# keys across and deliberately leaves the catsout group behind, so a blind
# rename would give the file two groups under one header. KConfig then reads the
# last one, and the stale pre-rename values win over whatever the user set
# since. Those groups keep their name and donate only the keys their captsilver
# twin lacks, which is the merge MigrationHelper::runIfNeeded() performs.
# Everything else (wallpaperplugin= and friends) is a plain URI substitution.
merge_uri_groups() {
    awk -v old="$OLD_URI" -v new="$NEW_URI" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function is_header(s) { return s ~ /^\[.*\][ \t]*$/ }
    function keyname(s,   i) { i = index(s, "="); return i ? trim(substr(s, 1, i - 1)) : "" }
    # Literal (not regex) replacement — the URIs are full of dots.
    function rep(s,   out, i) {
        while ((i = index(s, old)) > 0) {
            out = out substr(s, 1, i - 1) new
            s   = substr(s, i + length(old))
        }
        return out s
    }
    # Which keys move where, decided once the whole file has been read.
    function build_plan(   i, j, h, twin, line, k) {
        for (i = 1; i <= nhdr; i++) {
            h = hdr[i]
            if (index(h, old) == 0) continue
            twin = rep(h)
            if (! (twin in seen)) continue      # free to rename, nothing to merge
            for (j = 1; j <= nbody[h]; j++) {
                line = body[h, j]
                k    = keyname(line)
                if (k == "" || (twin, k) in has || (twin, k) in moved) continue
                moved[twin, k] = 1
                merge[twin, ++nmerge[twin]] = line
            }
        }
    }
    function emit_merged(   j) {
        for (j = 1; j <= nmerge[cur]; j++) print merge[cur, j]
    }
    # Group ends at the next header or EOF; merged keys go after its last
    # non-blank line so they cannot land in the blank gap before the next group.
    function flush(   i, last) {
        if (! open_block) return
        if (cur != "") print curout
        last = 0
        for (i = 1; i <= nbuf; i++) if (trim(buf[i]) != "") last = i
        if (last == 0) emit_merged()
        for (i = 1; i <= nbuf; i++) {
            print (keep ? buf[i] : rep(buf[i]))
            if (i == last) emit_merged()
        }
        nbuf = 0
    }
    FNR == NR {                                  # pass 1: index headers and keys
        line = trim($0)
        if (is_header(line)) {
            cur = line
            if (! (cur in seen)) { seen[cur] = 1; hdr[++nhdr] = cur }
            next
        }
        if (cur != "" && index($0, "=") > 0) {
            has[cur, keyname($0)] = 1
            body[cur, ++nbody[cur]] = $0
        }
        next
    }
    ! planned { build_plan(); planned = 1; cur = ""; open_block = 1; keep = 0 }
    {                                            # pass 2: rewrite
        line = trim($0)
        if (is_header(line)) {
            flush()
            cur  = line
            keep = (index(line, old) > 0 && (rep(line) in seen))
            curout = keep ? $0 : rep($0)
            open_block = 1
            next
        }
        buf[++nbuf] = $0
    }
    END { flush() }
    ' "$1" "$1"
}

rewrite_file() {
    local src=$1
    local dst="$src.tmp.$$"
    merge_uri_groups "$src" > "$dst" || {
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
while IFS= read -r f; do
    if grep -qF "$OLD_URI" "$f" 2>/dev/null; then
        rewrite_file "$f" || fail "rewrite of $f failed" 4
        REWRITE_COUNT=$((REWRITE_COUNT + 1))
    fi
done < <(config_files)
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
