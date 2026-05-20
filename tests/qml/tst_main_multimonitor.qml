import QtQuick
import QtTest
import Helpers 1.0

// Phase 2 focused lock: the REAL main.qml instantiated per-screen under a fake
// `wallpaper` context (ScreenRig). Locks "no `wallpaper is not defined` warning",
// per-screen backdrop-colour resolution, and the per-screen letterbox contract
// driven through the full Rectangle -> backendLoader -> Scene path. Config is
// mutated via rig.setConfig() (whole-object reassign so bindings re-fire — the
// configuration is a JS object since QML forbids uppercase property names).
TestCase {
    id: tc
    name: "Main_MultiMonitor"
    when: windowShown
    width: 400; height: 300

    Component { id: rigComp; ScreenRig {} }

    // ── instantiation + warning lock ────────────────────────────────────────
    function test_mainqml_instantiates_without_wallpaper_undefined() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        verify(rig !== null);
        tryVerify(() => rig.mainItem !== null, 2000, "main.qml failed to load into the rig");
        verify(rig.background() !== null);
        rig.destroy();
    }

    // ── per-screen backdrop colour ──────────────────────────────────────────
    function test_backdrop_falls_back_to_cfg_background_color() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        tryVerify(() => rig.background() !== null, 2000);
        verify(Qt.colorEqual(rig.background().color, "#0a0a0a"));   // WallpaperFake default
        rig.destroy();
    }

    function test_backdrop_uses_per_wallpaper_override() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        tryVerify(() => rig.fileHelper() !== null, 2000);
        rig.fileHelper()._wallpaperConfigReturns = { background_color: "#11aa33" };
        rig.setConfig({ PerOptChanged: 1 });    // re-fetch curOpt -> onCurOptChanged
        tryVerify(() => Qt.colorEqual(rig.background().color, "#11aa33"), 2000,
                  "per-wallpaper background_color did not resolve");
        rig.destroy();
    }

    // ── per-screen letterbox through full main.qml ──────────────────────────
    function _mkScene(w, h) {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, w, h) });
        verify(rig !== null);
        tryVerify(() => rig.mainItem !== null, 2000);
        // Seed a scene source -> source binding re-evals -> applySource -> Scene.
        rig.setConfig({
            SteamLibraryPath:    "/tmp/fakelib",
            WallpaperWorkShopId: "123",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/123/scene.pkg+scene"
        });
        tryVerify(() => rig.player() !== null, 2000, "SceneViewer never mounted");
        return rig;
    }

    function test_ultrawide_letterboxes_through_main() {
        const rig = _mkScene(3440, 1440);
        const p = rig.player();
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 2560);                 // 1440 * 16/9
        compare(Math.round(p.height), 1440);
        verify(p.width < rig.width);                        // side bars
        compare(Math.round(p.x), Math.round((rig.width - p.width) / 2));   // centred
        compare(p.fillMode, 0 /* STRETCH: renderer must NOT pad */);
        verify(Qt.colorEqual(rig.background().color, "#0a0a0a"));          // bars = backdrop
        rig.destroy();
    }

    function test_matched_aspect_fills_no_bars_through_main() {
        const rig = _mkScene(1920, 1080);
        const p = rig.player();
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 1920);
        compare(Math.round(p.height), 1080);
        rig.destroy();
    }

    function test_superwide_letterboxes_through_main() {
        const rig = _mkScene(5120, 1440);
        const p = rig.player();
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 2560);
        compare(p.fillMode, 0 /* STRETCH */);
        rig.destroy();
    }

    function test_portrait_letterboxes_through_main() {
        const rig = _mkScene(1080, 1920);
        const p = rig.player();
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 1080);
        compare(Math.round(p.height), 608);                 // 1080 / (16/9) = 607.5
        verify(p.height < rig.height);
        rig.destroy();
    }

    function test_unloaded_fills_screen_through_main() {
        const rig = _mkScene(3440, 1440);
        const p = rig.player();
        p.nativeAspectRatio = 0;
        compare(Math.round(p.width), 3440);
        compare(p.fillMode, 1 /* ASPECTFIT pre-load */);
        rig.destroy();
    }
}
