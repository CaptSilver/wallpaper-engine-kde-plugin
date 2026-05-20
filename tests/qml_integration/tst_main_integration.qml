import QtQuick
import QtTest

// True end-to-end: real main.qml + real config QObject (per-key NOTIFY) via the
// `wallpaper` context property. Proves the reactive Connections that the Phase-2
// JS-object rig cannot — with zero QJSValue/undefined warnings.
TestCase {
    id: tc
    name: "Main_Integration"
    when: windowShown
    width: 400; height: 300

    Item { id: host; anchors.fill: parent }

    function _find(node, pred) {
        if (!node) return null;
        const buckets = [node.children || [], node.data || []];
        for (const b of buckets)
            for (let i = 0; i < b.length; i++) {
                const c = b[i];
                if (c && pred(c)) return c;
                const deep = _find(c, pred);
                if (deep) return deep;
            }
        return null;
    }
    function _bg(m)     { return _find(m, o => typeof o.get_opt_value === "function"); }
    function _player(m) { return _find(m, o => typeof o.setAcceptMouse === "function"); }

    function _resetCfg() {
        // Shared context property -> reset the keys these tests touch.
        wallpaper.parent.screenGeometry = Qt.rect(0, 0, 1920, 1080);
        const c = wallpaper.configuration;
        c.DisplayMode = 0;            // Aspect
        c.BackgroundColor = "#0a0a0a";
        c.MuteAudio = false; c.Volume = 50; c.Speed = 1.0;
        c.WallpaperSource = ""; c.WallpaperWorkShopId = ""; c.SteamLibraryPath = "";
        c.PerOptChanged = 0;
    }

    function _mkMain(w, h) {
        const comp = Qt.createComponent("../../plugin/contents/ui/main.qml");
        compare(comp.status, Component.Ready);
        const m = comp.createObject(host, { width: w, height: h });
        verify(m !== null);
        return m;
    }

    // ── the Phase-2 gap: reactive config Connections actually fire ──────────
    function test_displayMode_connection_fires() {
        failOnWarning(/Unable to assign QJSValue|wallpaper is not defined/);
        _resetCfg();
        const m = _mkMain(1920, 1080);
        const bg = _bg(m);
        wallpaper.configuration.DisplayMode = 2;     // Scale, at runtime
        tryCompare(bg, "displayMode", 2);            // onDisplayModeChanged fired
        m.destroy();
    }

    function test_backgroundColor_connection_fires() {
        failOnWarning(/Unable to assign QJSValue|wallpaper is not defined/);
        _resetCfg();
        const m = _mkMain(1920, 1080);
        const bg = _bg(m);
        wallpaper.configuration.BackgroundColor = "#123456";
        tryVerify(() => Qt.colorEqual(bg.color, "#123456"), 2000);
        m.destroy();
    }

    function test_mute_volume_speed_connections_fire() {
        failOnWarning(/Unable to assign QJSValue|wallpaper is not defined/);
        _resetCfg();
        const m = _mkMain(1920, 1080);
        const bg = _bg(m);
        wallpaper.configuration.MuteAudio = true;
        wallpaper.configuration.Volume = 25;
        wallpaper.configuration.Speed = 2.0;
        tryCompare(bg, "mute", true);
        tryCompare(bg, "volume", 25);
        tryCompare(bg, "speed", 2.0);
        m.destroy();
    }

    // ── per-screen letterbox through main.qml-as-root, full fidelity ────────
    function _mkScene(w, h) {
        failOnWarning(/Unable to assign QJSValue|wallpaper is not defined/);
        _resetCfg();
        wallpaper.parent.screenGeometry = Qt.rect(0, 0, w, h);
        wallpaper.configuration.DisplayMode = 0;     // Aspect (main.xml default is 1=Crop!)
        wallpaper.configuration.SteamLibraryPath = "/tmp/fakelib";
        wallpaper.configuration.WallpaperWorkShopId = "123";
        wallpaper.configuration.WallpaperSource =
            "/tmp/fakelib/steamapps/workshop/content/431960/123/scene.pkg+scene";
        const m = _mkMain(w, h);
        tryVerify(() => _player(m) !== null, 2000, "SceneViewer never mounted");
        return m;
    }

    function test_ultrawide_letterboxes_end_to_end() {
        const m = _mkScene(3440, 1440);
        const p = _player(m);
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 2560);
        compare(Math.round(p.height), 1440);
        compare(p.fillMode, 0 /* STRETCH */);
        verify(Qt.colorEqual(_bg(m).color, "#0a0a0a"));
        m.destroy();
    }

    function test_portrait_letterboxes_end_to_end() {
        const m = _mkScene(1080, 1920);
        const p = _player(m);
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 1080);
        compare(Math.round(p.height), 608);
        m.destroy();
    }
}
