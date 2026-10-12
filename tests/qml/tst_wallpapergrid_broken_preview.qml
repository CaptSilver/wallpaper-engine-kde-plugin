// The settings page shows every wallpaper's preview.gif as an animated
// preview. Qt 6.12's AnimatedImage recurses until the stack overflows on a
// multi-frame GIF whose first frame fails to decode, so a single broken
// preview in the library crashed System Settings or plasmashell as soon as
// the page opened. The grid and the detail pane must keep such a file away
// from AnimatedImage; on Qt 6.12 this test crashes the runner if they don't.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperGridBrokenPreview"
    width: 1024; height: 768
    when: windowShown

    Item { id: host; anchors.fill: parent }

    property var cfg: null
    property var page: null
    property var picLoader: null
    property var grid: null

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

        picLoader = _findFirstByPredicate(page, n =>
            n && n.hasOwnProperty("sourceComponent") &&
            n.hasOwnProperty("item") && n.item &&
            n.item.hasOwnProperty("view") && n.item.view &&
            typeof n.item.view.count === "number");
        verify(picLoader, "picViewLoader not found inside WallpaperPage");
        grid = picLoader.item;
        verify(grid && grid.view, "grid.view not reachable");
    }

    function _entry(id, preview) {
        const dir = Qt.resolvedUrl("../fixtures/previews").toString();
        return { workshopid: id, path: dir, file: "scene.pkg", type: "scene", title: "T" + id,
                 preview: preview, contentrating: "Everyone", tags: [], favor: false,
                 playlists: [], loaded: true, modified: 1 };
    }

    function _isAnimatedImage(n) {
        return n && n.toString && n.toString().indexOf("QQuickAnimatedImage") === 0;
    }

    function test_a_broken_preview_never_reaches_AnimatedImage() {
        const m = grid.view.model;
        m.clear();
        m.append(_entry("901", "bad_first_frame.gif"));
        grid.reducedMotion = false;
        grid.animatedPreviewActive = true;
        tryVerify(() => grid.view.itemAtIndex(0) != null, 2000, "delegate never materialised");
        grid.view.currentIndex = 0;   // the detail pane shows it too
        wait(1000);
        compare(_findFirstByPredicate(cfg, _isAnimatedImage), null);
    }

    function test_a_decodable_preview_still_animates() {
        const m = grid.view.model;
        m.clear();
        m.append(_entry("902", "animated.gif"));
        grid.reducedMotion = false;
        grid.animatedPreviewActive = true;
        tryVerify(() => grid.view.itemAtIndex(0) != null, 2000, "delegate never materialised");
        tryVerify(() => _findFirstByPredicate(grid.view.itemAtIndex(0), _isAnimatedImage) != null,
                  3000, "a decodable preview never animated");
    }
}
