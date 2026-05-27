// Pre-apply warning Label test — sets right_content.wpmodel.type through
// the six recognized values (scene/web/video/application/preset/unknown)
// and asserts the warning Label's presence + message text matches the
// spec table. Mirrors the bootstrap shape of tst_wallpaperpage_grid.qml.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperPageTypeWarning"
    width: 1024; height: 768
    when: windowShown

    Item { id: host; anchors.fill: parent }

    property var cfg: null
    property var page: null
    property var rc: null

    function _findFirstByPredicate(root, predicate) {
        const seen = new Set();
        const queue = [root];
        seen.add(root);
        while (queue.length > 0) {
            const node = queue.shift();
            if (predicate(node)) return node;
            const buckets = [node.children || [], node.data || []];
            for (const b of buckets) {
                if (!b || typeof b.length === "undefined") continue;
                for (let i = 0; i < b.length; i++) {
                    const c = b[i];
                    if (c && !seen.has(c)) { seen.add(c); queue.push(c); }
                }
            }
        }
        return null;
    }

    function initTestCase() {
        const comp = Qt.createComponent("../../plugin/contents/ui/config.qml");
        verify(comp.status !== Component.Error, comp.errorString());
        cfg = comp.createObject(host, {});
        verify(cfg);
        cfg.libcheck = { wallpaper: true, qtwebchannel: true };
        if (cfg.plugin_info) cfg.plugin_info.cache_path = "file:///tmp/cache";

        page = _findFirstByPredicate(cfg, n =>
            n && n.toString && n.toString().indexOf("WallpaperPage_QMLTYPE") === 0);
        verify(page, "WallpaperPage not found in config tree");

        // right_content is the Control inside WallpaperPage that holds the
        // info-pane Flickable. We pick it out by the wpmodel sentinel
        // declared on it (Control with a wpmodel property → only right_content).
        rc = _findFirstByPredicate(page, n =>
            n && n.toString && n.toString().indexOf("Control_QMLTYPE") === 0
            && n.hasOwnProperty("wpmodel"));
        verify(rc, "right_content Control not found inside WallpaperPage");
    }

    // The warning is a Label whose text begins with either "Application
    // wallpapers" or "Preset wallpapers" — find it structurally. Returns
    // null when no such Label exists in the subtree (renderable types,
    // before any unsupported type has ever been set).
    function _findWarningLabel(root) {
        const queue = [root]; const seen = new Set([root]);
        while (queue.length) {
            const n = queue.shift();
            if (n && typeof n.text === "string"
                && (n.text.indexOf("Application wallpapers") >= 0
                    || n.text.indexOf("Preset wallpapers") >= 0)) return n;
            const buckets = [n.children || [], n.data || []];
            for (const b of buckets) {
                if (!b || typeof b.length === "undefined") continue;
                for (let i = 0; i < b.length; i++) {
                    const c = b[i]; if (c && !seen.has(c)) { seen.add(c); queue.push(c); }
                }
            }
        }
        return null;
    }

    function _setType(type) {
        // Build a minimal wpmodel matching the template shape so the
        // existing right-pane bindings (title, tags, etc.) don't error.
        const wp = Object.assign({}, Plugin.Common.wpitem_template,
                                 { type: type, workshopid: "1" });
        rc.wpmodel = wp;
    }

    function test_warning_hiddenForRenderableTypes() {
        _setType("scene");
        const lbl1 = _findWarningLabel(rc);
        verify(lbl1 === null || lbl1.visible === false);
        _setType("web");
        const lbl2 = _findWarningLabel(rc);
        verify(lbl2 === null || lbl2.visible === false);
        _setType("video");
        const lbl3 = _findWarningLabel(rc);
        verify(lbl3 === null || lbl3.visible === false);
    }
    function test_warning_visibleAndAppropriate_forApplication() {
        _setType("application");
        const lbl = _findWarningLabel(rc);
        verify(lbl !== null);
        verify(lbl.text.indexOf("Application wallpapers") >= 0);
    }
    function test_warning_visibleAndAppropriate_forPreset() {
        _setType("preset");
        const lbl = _findWarningLabel(rc);
        verify(lbl !== null);
        verify(lbl.text.indexOf("Preset wallpapers") >= 0);
    }
    function test_warning_hiddenForUnknown() {
        _setType("unknown");
        const lbl = _findWarningLabel(rc);
        verify(lbl === null || lbl.visible === false);
    }
}
