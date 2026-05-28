// Screen-reader (Orca) hooks on the shared WallpaperGrid surface.  Assertion
// targets: the GridView root carries a List role + propagatable accessibleName;
// each delegate carries a ListItem role, a name that falls back to workshopid
// when title is blank, and a description that surfaces the unrenderable-type
// badge ("Unsupported: Windows application" / "Unsupported: preset overlay").
// The right-click MouseArea is marked Accessible.ignored to avoid double-
// announcement of the same tile.
//
// We piggy-back on the same config.qml → WallpaperPage → WallpaperGrid path the
// existing tst_wallpaperpage_grid uses, so the singleton imports (Common,
// PlasmaCore, KCM) resolve identically to production.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperGridAccessible"
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

    function _injectFixtureModel(items) {
        const m = grid.view.model;
        m.clear();
        for (let i = 0; i < items.length; i++) m.append(items[i]);
    }

    function _fakeItem(id, type, title) {
        return {
            workshopid: String(id),
            path: "file:///tmp/wp_" + id,
            file: "scene.pkg",
            type: type || "scene",
            title: typeof title === "string" ? title : ("Wallpaper " + id),
            preview: "",
            contentrating: "Everyone",
            tags: [],
            favor: false,
            playlists: [],
            loaded: true,
            modified: 1000 + id,
        };
    }

    function test_grid_root_has_list_role() {
        // WallpaperPage passes accessibleName="Wallpaper Engine wallpapers" through;
        // the grid root reflects that and the List role.
        compare(grid.Accessible.role, Accessible.List);
        compare(grid.Accessible.name, "Wallpaper Engine wallpapers");
    }

    function test_grid_accessibleName_is_overridable() {
        const old = grid.accessibleName;
        grid.accessibleName = "Custom announcement";
        compare(grid.Accessible.name, "Custom announcement");
        grid.accessibleName = old;
    }

    function test_delegate_announces_title_and_workshopid_fallback() {
        // Both axes of the `title || workshopid` fallback in one fixture so
        // we sidestep delegate-recycle staleness across separate test cases
        // (model.clear()+append re-uses the existing delegate at index 0).
        _injectFixtureModel([
            _fakeItem(42, "scene", "Totoro"),
            _fakeItem(999, "scene", ""),
        ]);
        tryVerify(() => grid.view.itemAtIndex(0) != null
                     && grid.view.itemAtIndex(1) != null, 2000,
                  "delegates never materialised");

        const d0 = grid.view.itemAtIndex(0);
        compare(d0.Accessible.role, Accessible.ListItem);
        compare(d0.Accessible.name, "Totoro");

        const d1 = grid.view.itemAtIndex(1);
        compare(d1.Accessible.role, Accessible.ListItem);
        compare(d1.Accessible.name, "999");
    }

    function test_delegate_description_covers_all_types() {
        // Single fixture covers all four announced cases — exercises the
        // ternary chain in one delegate-materialisation pass rather than
        // racing against delegate-recycling when the model is cleared.
        _injectFixtureModel([
            _fakeItem(1, "scene"),
            _fakeItem(2, "web"),
            _fakeItem(3, "application"),
            _fakeItem(4, "preset"),
        ]);
        tryVerify(() => grid.view.itemAtIndex(0) != null
                     && grid.view.itemAtIndex(1) != null
                     && grid.view.itemAtIndex(2) != null
                     && grid.view.itemAtIndex(3) != null, 2000,
                  "delegates never materialised");

        compare(grid.view.itemAtIndex(0).Accessible.description, "scene");
        compare(grid.view.itemAtIndex(1).Accessible.description, "web");
        compare(grid.view.itemAtIndex(2).Accessible.description,
                "Unsupported: Windows application");
        compare(grid.view.itemAtIndex(3).Accessible.description,
                "Unsupported: preset overlay");
    }
}
