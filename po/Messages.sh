#!/bin/sh
# Extract translatable strings from QML/JS for KDE Scripty / xgettext.
# Run before each release tag to refresh the .pot template; commit the
# regenerated .pot alongside the wrap PR.

CATALOG=plasma_wallpaper_com.github.captsilver.wallpaperEngineKde

find ../plugin/contents/ui -name '*.qml' -o -name '*.mjs' -o -name '*.js' \
    | xargs xgettext --c++ --kde \
        --from-code=UTF-8 \
        --output=${CATALOG}.pot \
        --keyword=i18n --keyword=i18nc:1c,2 --keyword=i18np:1,2 \
        --keyword=i18ncp:1c,2,3 \
        --keyword=i18nd:2 --keyword=i18ndc:2c,3 \
        --keyword=i18ndp:2,3 --keyword=i18ndcp:2c,3,4 \
        --package-name="wallpaper-engine-kde-plugin" \
        --copyright-holder="CaptSilver"
