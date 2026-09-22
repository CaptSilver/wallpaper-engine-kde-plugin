// Production QML never imports org.kde.plasma.core just to reach i18n*() --
// plasmashell (and PlasmaCore's own initializeEngine) installs a
// KLocalizedContext on the engine's root context once, and every loaded
// file inherits the globals from there. This test pins that same behaviour
// in the offscreen test harness: it imports nothing beyond QtQuick/QtTest,
// so a pass here only means the harness itself is wiring i18n bindings the
// way plasmashell does, not that some file's own import happened to supply
// them as a side effect.
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "I18nBindings"

    function test_i18nGlobals_areFunctions() {
        compare(typeof i18n, "function");
        compare(typeof i18nc, "function");
        compare(typeof i18np, "function");
        compare(typeof i18ncp, "function");
    }

    function test_i18nc_returnsMessageUntranslated() {
        compare(i18nc("test context", "Hello"), "Hello");
    }
}
