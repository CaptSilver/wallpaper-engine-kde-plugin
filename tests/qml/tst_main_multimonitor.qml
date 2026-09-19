import QtQuick
import QtTest
import Helpers 1.0
import com.github.captsilver.wallpaperEngineKde 1.2

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

    // Web wallpapers name their WebEngineProfile storage after the workshop
    // id, and Chromium keeps the StoragePartition it already built once a
    // profile is live: renaming it moves cookies and cache but not
    // localStorage. So a different web wallpaper must get a fresh backend,
    // while a source edit on the SAME wallpaper keeps the mounted view.
    function test_web_to_web_switch_mounts_fresh_backend() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        verify(rig !== null);
        tryVerify(() => rig.mainItem !== null, 2000);

        rig.setConfig({
            SteamLibraryPath:    "/tmp/fakelib",
            WallpaperWorkShopId: "111",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/111/index.html+web"
        });
        tryVerify(() => rig.webView() !== null, 2000, "web backend never mounted");
        const first = rig.webView();

        rig.setConfig({
            WallpaperWorkShopId: "222",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/222/index.html+web"
        });
        tryVerify(() => rig.webView() !== null && rig.webView() !== first, 2000,
            "web->web switch reused the previous backend");
        const second = rig.webView();
        compare(second.wallpaperProfile.storageName, "wek-wp-222");

        // Same workshop id, different path: no rebuild.
        rig.setConfig({
            WallpaperSource: "/tmp/fakelib/steamapps/workshop/content/431960/222/other.html+web"
        });
        wait(200);
        verify(rig.webView() === second, "path-only change must not rebuild the backend");

        rig.destroy();
    }

    // A fast A -> B -> A switch must never leave two live profile objects on
    // A's storage name. Each backend swap builds a fresh QtWebView (see
    // above), which used to mean a fresh WebEngineProfile too; now the view
    // is fresh but the profile is looked up by name, so returning to A must
    // hand back A's original object, and the process-wide (here: per-engine)
    // profile count must stay at two distinct wallpapers, not three.
    function test_web_to_web_to_web_aba_sharesOneProfilePerName() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        verify(rig !== null);
        tryVerify(() => rig.mainItem !== null, 2000);

        rig.setConfig({
            SteamLibraryPath:    "/tmp/fakelib",
            WallpaperWorkShopId: "333",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/333/index.html+web"
        });
        tryVerify(() => rig.webView() !== null, 2000, "web backend A never mounted");
        const profileA       = rig.webView().wallpaperProfile;
        const countAfterA    = WebProfileRegistryStore.liveProfileCount();

        rig.setConfig({
            WallpaperWorkShopId: "444",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/444/index.html+web"
        });
        tryVerify(() => rig.webView() !== null && rig.webView().wallpaperProfile !== profileA, 2000,
            "web->web switch to B never mounted");
        compare(WebProfileRegistryStore.liveProfileCount(), countAfterA + 1,
            "switching to B must create exactly one new profile");

        rig.setConfig({
            WallpaperWorkShopId: "333",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/333/index.html+web"
        });
        tryVerify(() => rig.webView() !== null && rig.webView().wallpaperProfile === profileA, 2000,
            "switching back to A must reuse A's profile object, not build a second one");
        compare(WebProfileRegistryStore.liveProfileCount(), countAfterA + 1,
            "A-B-A must not grow the live profile count past the two distinct wallpapers involved");

        rig.destroy();
    }

    // The other collision a per-name profile scheme leaves on the table by
    // design (see qtwebengine-profile-storagename-semantics in the project
    // memory): the SAME web wallpaper shown on two monitors. Both screens'
    // QtWebView must resolve to the identical profile object -- two objects
    // that merely share a storageName string is the exact bug this class
    // exists to rule out.
    function test_two_screens_sameWebWallpaper_shareOneProfile() {
        failOnWarning(/wallpaper is not defined/);
        const rigA = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        const rigB = rigComp.createObject(tc, { screenGeometry: Qt.rect(1920, 0, 1920, 1080) });
        verify(rigA !== null);
        verify(rigB !== null);
        tryVerify(() => rigA.mainItem !== null && rigB.mainItem !== null, 2000);

        const cfg = {
            SteamLibraryPath:    "/tmp/fakelib",
            WallpaperWorkShopId: "555",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/555/index.html+web"
        };
        rigA.setConfig(cfg);
        rigB.setConfig(cfg);
        tryVerify(() => rigA.webView() !== null && rigB.webView() !== null, 2000,
            "both screens must mount a web backend");

        compare(rigA.webView().wallpaperProfile, rigB.webView().wallpaperProfile,
            "the same web wallpaper on two screens must share one profile object");

        rigA.destroy();
        rigB.destroy();
    }

    // loadBackend() passes workshopId at construction from
    // wallpaper.configuration.WallpaperWorkShopId directly, not from
    // background.workshopid: when WallpaperWorkShopId and WallpaperSource
    // change in the same tick, workshopid's own binding may not have
    // re-evaluated yet by construction time (applySource() reads the
    // configuration directly for the same reason).
    //
    // QtWebView.qml's workshopId has no default binding at all (not even to
    // background.workshopid), so there is no separate evaluation of it left
    // to race: the ONLY value it is ever given is this constructor
    // property, supplied once, already correct. The swap must never touch
    // the OLD id's profile at any point -- on a scene<->web swap the OLD id
    // may not even have a web profile, so "just" re-querying it would build
    // one nobody asked for.
    function test_simultaneousIdAndSourceChange_neverLooksUpTheOldId() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        verify(rig !== null);
        tryVerify(() => rig.mainItem !== null, 2000);

        rig.setConfig({
            SteamLibraryPath:    "/tmp/fakelib",
            WallpaperWorkShopId: "666",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/666/index.html+web"
        });
        tryVerify(() => rig.webView() !== null, 2000, "first web backend never mounted");
        const countBeforeSwap = WebProfileRegistryStore.liveProfileCount();
        WebProfileRegistryStore.resetCalls(); // reset the recorder for this swap

        rig.setConfig({
            WallpaperWorkShopId: "777",
            WallpaperSource:     "/tmp/fakelib/steamapps/workshop/content/431960/777/index.html+web"
        });
        tryVerify(() => rig.webView() !== null && rig.webView().workshopId === "777", 2000,
            "the newly mounted view must carry the NEW workshop id");

        compare(rig.webView().wallpaperProfile.storageName, "wek-wp-777",
            "the mounted view's profile must belong to the NEW wallpaper");
        compare(WebProfileRegistryStore.liveProfileCount(), countBeforeSwap + 1,
            "the swap must create exactly one new profile (for 777) -- none wasted on 666");
        const calls = WebProfileRegistryStore.callsSnapshot();
        verify(calls.indexOf("666") === -1,
            "the swap must never look up the OLD id's profile");
        verify(calls.indexOf("777") !== -1,
            "the swap must look up the NEW id's profile");

        rig.destroy();
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
