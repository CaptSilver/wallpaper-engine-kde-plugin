// Reduce-motion plumbing.  Two layers:
//   1. `hasOwnProperty('hasReducedAnimations')` guard returns `false` on
//      Kirigami builds that don't expose the property (Plasma 6.0/6.1 era
//      and the Fedora distrobox at the time of writing) — verified by
//      reading the WallpaperGrid root's `reducedMotion` property.
//   2. The AnimatedImage preview Loader's sourceComponent picks animatedPre
//      vs staticPre using `(animatedPreviewActive && !reducedMotion)`.
//      We exercise both axes by toggling animatedPreviewActive and the
//      grid's `reducedMotion` (override the read-only binding via direct
//      assignment in JS — Qt accepts this).
//
// The fade-duration gating in main.qml's Behaviors is asserted via source-
// text grep (XHR), the same pattern tst_main.qml uses to lock binding form.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "ReducedMotion"
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

    function test_reducedMotion_property_exposed() {
        // The WallpaperGrid root carries a `reducedMotion` property.  The
        // value is whatever the live Kirigami.Settings reports for
        // hasReducedAnimations, OR `false` when the property is absent on
        // the host build (Plasma 6.0/6.1 fallback).
        verify(grid.hasOwnProperty("reducedMotion"));
        verify(typeof grid.reducedMotion === "boolean");
    }

    function test_animatedPreviewLoader_picks_static_when_reducedMotion_true() {
        // The Loader's sourceComponent reads
        //   (animatedPreviewActive && !reducedMotion) ? animatedPre : staticPre
        // When animatedPreviewActive=true AND reducedMotion=true, staticPre wins.
        const m = grid.view.model;
        m.clear();
        m.append({
            workshopid: "1", path: "file:///tmp/wp_1", file: "scene.pkg",
            type: "scene", title: "T1", preview: "", contentrating: "Everyone",
            tags: [], favor: false, playlists: [], loaded: true, modified: 1,
        });
        tryVerify(() => grid.view.itemAtIndex(0) != null, 2000,
                  "delegate never materialised");

        grid.reducedMotion = false;
        grid.animatedPreviewActive = true;
        // animated path: scene with reducedMotion=false + AnimatedPreview=true.
        // The Loader's child component is the AnimatedImage form.

        // Now flip reducedMotion: source must switch to static.
        grid.reducedMotion = true;
        // The downstream Loader rebuilds. Find any Image-but-not-AnimatedImage
        // child within the delegate's thumbnail subtree.
        const d = grid.view.itemAtIndex(0);
        verify(d);
        const isAnimated = _findFirstByPredicate(d, n =>
            n && n.toString && n.toString().indexOf("QQuickAnimatedImage") === 0);
        // staticPre's Image is NOT an AnimatedImage; if reducedMotion ⇒ static,
        // we must not find an AnimatedImage instance.
        compare(isAnimated, null);
    }

    function test_animatedPreviewLoader_picks_animated_when_both_on() {
        const m = grid.view.model;
        m.clear();
        m.append({
            workshopid: "2", path: "file:///tmp/wp_2", file: "scene.pkg",
            type: "scene", title: "T2", preview: "", contentrating: "Everyone",
            tags: [], favor: false, playlists: [], loaded: true, modified: 2,
        });
        tryVerify(() => grid.view.itemAtIndex(0) != null, 2000,
                  "delegate never materialised");

        grid.reducedMotion = false;
        grid.animatedPreviewActive = true;
        const d = grid.view.itemAtIndex(0);
        tryVerify(() => _findFirstByPredicate(d, n =>
            n && n.toString && n.toString().indexOf("QQuickAnimatedImage") === 0
        ) != null, 2000, "AnimatedImage form never picked");
    }

    function test_animatedPreviewLoader_picks_static_when_user_pref_off() {
        const m = grid.view.model;
        m.clear();
        m.append({
            workshopid: "3", path: "file:///tmp/wp_3", file: "scene.pkg",
            type: "scene", title: "T3", preview: "", contentrating: "Everyone",
            tags: [], favor: false, playlists: [], loaded: true, modified: 3,
        });
        tryVerify(() => grid.view.itemAtIndex(0) != null, 2000,
                  "delegate never materialised");

        grid.reducedMotion = false;
        grid.animatedPreviewActive = false;
        const d = grid.view.itemAtIndex(0);
        // No AnimatedImage when the user pref is off, regardless of reducedMotion.
        const isAnimated = _findFirstByPredicate(d, n =>
            n && n.toString && n.toString().indexOf("QQuickAnimatedImage") === 0);
        compare(isAnimated, null);
    }

    // ── main.qml fade-Behavior structural assertions (source-text grep) ──
    // Pattern mirrors tst_main.qml::test_workshopid_isPureBinding_noSideEffectInDecl.
    // QML_XHR_ALLOW_FILE_READ=1 is set by the ctest harness for this suite.
    function _readMainQmlSource() {
        const req = new XMLHttpRequest();
        req.open("GET", Qt.resolvedUrl("../../plugin/contents/ui/main.qml"), false);
        req.send(null);
        return req.responseText || "";
    }

    function test_main_qml_imports_kirigami() {
        const src = _readMainQmlSource();
        verify(src.length > 0, "main.qml source not readable");
        verify(src.indexOf("import org.kde.kirigami") >= 0,
               "main.qml must import org.kde.kirigami for the reducedMotion read");
    }

    function test_main_qml_reducedMotion_uses_hasOwnProperty_guard() {
        // The defensive guard is load-bearing on Plasma 6.0/6.1 where
        // hasReducedAnimations may not be defined on Kirigami.Settings.
        const src = _readMainQmlSource();
        verify(src.indexOf("reducedMotion") >= 0,
               "main.qml must define a reducedMotion property");
        verify(src.indexOf("hasOwnProperty('hasReducedAnimations')") >= 0,
               "main.qml's reducedMotion read must hasOwnProperty-guard");
    }

    function test_main_qml_fade_behaviors_gate_on_reducedMotion() {
        // Both Behavior on opacity blocks must read background.reducedMotion
        // — otherwise the playlist-tick fade or the loading-hint fade still
        // runs under the "Reduce animations" system pref.
        const src = _readMainQmlSource();
        // Two ternaries in the form "background.reducedMotion ? 0 : 250"
        const re = /background\.reducedMotion\s*\?\s*0\s*:\s*250/g;
        const matches = src.match(re) || [];
        verify(matches.length >= 2,
               "expected ≥2 'background.reducedMotion ? 0 : 250' gates "
               + "in main.qml, found " + matches.length);
    }
}
