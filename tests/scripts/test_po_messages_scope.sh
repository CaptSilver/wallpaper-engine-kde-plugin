#!/usr/bin/env bash
# Regression test for po/Messages.sh's extraction scope: it must reach the
# plugin's own top-level C++ files and data/wek.notifyrc, and must NOT sweep
# the backend_scene/backend_mpv build targets (a separate renderer submodule
# with no user-facing plugin strings).
set -uo pipefail

SKIP_CODE=77

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <repo-root>" >&2
    exit 1
fi
REPO=$(cd "$1" && pwd)

if ! command -v xgettext >/dev/null 2>&1; then
    echo "xgettext not on PATH -- skipping" >&2
    exit "$SKIP_CODE"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/po" "$TMP/src" "$TMP/data"
cp "$REPO/po/Messages.sh" "$TMP/po/Messages.sh"
ln -s "$REPO/plugin" "$TMP/plugin"
# NOT `ln -s "$REPO/src" "$TMP/src"`: po/Messages.sh's `find ../src -maxdepth 1
# ...` treats a starting-point argument that is *itself* a symlink specially --
# GNU find's default -P mode reports a symlink-to-directory given directly as
# the search path as one leaf result and never descends into it (no trailing
# slash, no -L), so a directory-level symlink here would make every check
# below fail even after the real fix lands.  ../plugin/contents/ui doesn't hit
# this: `plugin` there is an *intermediate* path component, which normal path
# resolution follows transparently regardless of find's symlink handling --
# only the very last component of the whole argument is special-cased.  A real
# directory containing per-file symlinks sidesteps it entirely (verified: 0
# files matched with a directory symlink, 44 matched with per-file symlinks
# into a real directory).
for f in "$REPO"/src/*.cpp "$REPO"/src/*.hpp; do
    ln -s "$f" "$TMP/src/$(basename "$f")"
done
ln -s "$REPO/data/wek.notifyrc" "$TMP/data/wek.notifyrc"

PASS=0
FAIL=0

( cd "$TMP/po" && sh Messages.sh ) >"$TMP/messages.log" 2>&1
POT="$TMP/po/plasma_wallpaper_com.github.captsilver.wallpaperEngineKde.pot"
if [[ ! -f "$POT" ]]; then
    echo "FAIL: Messages.sh produced no .pot -- log:"
    cat "$TMP/messages.log"
    exit 1
fi

check() {
    local name="$1" pattern="$2" want_present="$3"
    if grep -qF -- "$pattern" "$POT"; then
        found=1
    else
        found=0
    fi
    if [[ "$found" == "$want_present" ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (expected present=$want_present, got present=$found)"
        FAIL=$((FAIL + 1))
    fi
}

check "WekNotifier string reaches the pot"    'msgid "Wallpaper could not be loaded"'      1
check "WekShortcuts string reaches the pot"   'msgid "Next wallpaper in playlist"'         1
check "WekDiagnostics string reaches the pot" 'msgid "Failed to create cache dir: %1"'     1
# "Wallpaper failed to load" (the more obvious pick, [Event/wallpaperLoadFailed]'s
# Name=) is NOT usable here: plugin/contents/ui/backend/InfoShow.qml:53 already
# wraps that exact same English text for an unrelated purpose, so it's in the
# .pot from the QML pass alone, before the notifyrc pass exists -- checking for
# it would falsely PASS today and prove nothing. This string is unique to
# data/wek.notifyrc (confirmed: no hits anywhere under plugin/contents/ui).
check "wek.notifyrc string reaches the pot" 'msgid "Wallpaper Engine for KDE Plasma 6"' 1
# Regression guard, not a red/green pair: this is already true today (there's
# no ../src scan at all yet), and must stay true once ../src is scanned --
# an unscoped `find ../src` (no -maxdepth 1) would sweep the 2257-file
# backend_scene submodule and start failing this.
check "no backend_scene leakage into the pot" 'backend_scene' 0
check "no backend_mpv leakage into the pot"   'backend_mpv'   0

echo "== $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
