#!/bin/sh
# Extract translatable strings from QML/JS/C++/wek.notifyrc for KDE Scripty /
# xgettext. Run before each release tag to refresh the .pot template; commit
# the regenerated .pot alongside the wrap PR.

CATALOG=plasma_wallpaper_com.github.captsilver.wallpaperEngineKde

# ../src also contains the backend_scene/backend_mpv build targets -- a
# separate Vulkan renderer submodule (plus vendored third_party/) with no
# user-facing plugin strings.  -maxdepth 1 keeps this scoped to the plugin's
# own top-level C++ (WekNotifier.cpp, WekShortcuts.cpp, ...).
find ../plugin/contents/ui -name '*.qml' -o -name '*.mjs' -o -name '*.js' \
    | cat - <(find ../src -maxdepth 1 -name '*.cpp' -o -name '*.hpp') \
    | xargs xgettext --c++ --kde \
        --from-code=UTF-8 \
        --output=${CATALOG}.pot \
        --keyword=i18n --keyword=i18nc:1c,2 --keyword=i18np:1,2 \
        --keyword=i18ncp:1c,2,3 \
        --keyword=i18nd:2 --keyword=i18ndc:2c,3 \
        --keyword=i18ndp:2,3 --keyword=i18ndcp:2c,3,4 \
        --package-name="wallpaper-engine-kde-plugin" \
        --copyright-holder="CaptSilver"

# wek.notifyrc's Name=/Comment= keys aren't C++ or QML; gettext's native
# Desktop-entry mode reads INI-style translatable keys directly (no extra
# tool -- this is the same `gettext` package that already provides
# xgettext above). --join-existing merges into the same .pot instead of a
# second file, so translators work from one catalog.
xgettext -L Desktop --from-code=UTF-8 \
    --join-existing --output=${CATALOG}.pot \
    --package-name="wallpaper-engine-kde-plugin" \
    --copyright-holder="CaptSilver" \
    ../data/wek.notifyrc
