import QtQuick
import QtTest
import Helpers 1.0
import com.github.captsilver.wallpaperEngineKde 1.2

// Wallpaper-to-wallpaper handoff through the REAL main.qml (ScreenRig): the
// backend on screen stays up, still playing and with its own options, until
// the next one reports its first frame; only then does it fade out and go.
// Before this, the old backend faded out at once and a cold scene start
// showed the bare background (and the desktop icons) for seconds, and the
// old wallpaper briefly took the next one's display mode.
TestCase {
    id: tc
    name: "Main_Handoff"
    when: windowShown
    width: 400; height: 300

    Component { id: rigComp; ScreenRig {} }

    function _scenePath(id) {
        return "/tmp/fakelib/steamapps/workshop/content/431960/" + id + "/scene.pkg+scene";
    }
    function _loader(rig) { return rig._find(rig.mainItem, o => typeof o.dropOutgoing === "function"); }
    function _playerOf(backend) { return rig_find(backend, o => typeof o.setAcceptMouse === "function"); }
    function rig_find(node, pred) {
        if (!node) return null;
        if (pred(node)) return node;
        const kids = (node.children || []).concat(node.data || []);
        for (let i = 0; i < kids.length; i++) {
            const hit = rig_find(kids[i], pred);
            if (hit) return hit;
        }
        return null;
    }

    function _mkRigWithScene(id) {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        verify(rig !== null);
        tryVerify(() => rig.mainItem !== null, 2000);
        rig.setConfig({
            SteamLibraryPath:    "/tmp/fakelib",
            WallpaperWorkShopId: id,
            WallpaperSource:     _scenePath(id)
        });
        tryVerify(() => _loader(rig) && _loader(rig).item && _playerOf(_loader(rig).item), 2000,
                  "first scene never mounted");
        return rig;
    }

    function _switchTo(rig, id) {
        rig.setConfig({ WallpaperWorkShopId: id, WallpaperSource: _scenePath(id) });
    }

    function test_old_scene_stays_until_new_one_draws() {
        const rig = _mkRigWithScene("111");
        const loader = _loader(rig);
        const first = loader.item;
        _playerOf(first).firstFrame();
        verify(first.frameShown);

        _switchTo(rig, "222");
        tryVerify(() => loader.item && loader.item !== first, 2000, "no fresh backend for scene->scene");
        const second = loader.item;
        // The new scene has not drawn yet: the old one is still up, on top.
        verify(loader._outgoing === first, "old scene dropped before the new one drew");
        compare(first.opacity, 1);
        verify(first.z > second.z);

        _playerOf(second).firstFrame();
        tryVerify(() => loader._outgoing === null, 2000);
        // Faded out and destroyed after the 250 ms fade.
        tryVerify(() => { try { return first.opacity === undefined || first.opacity === 0; } catch (e) { return true; } },
                  2000, "outgoing scene never faded out");
        rig.destroy();
    }

    function test_outgoing_scene_keeps_its_own_display_mode() {
        const rig = _mkRigWithScene("111");
        const loader = _loader(rig);
        const first = loader.item;
        _playerOf(first).firstFrame();
        const modeBefore = first.displayMode;

        // The next wallpaper has its own fill mode (e.g. "stretch").
        const nextMode = (modeBefore + 1) % 3;
        rig.fileHelper()._wallpaperConfigReturns = { display_mode: nextMode };
        _switchTo(rig, "222");
        tryVerify(() => loader.item && loader.item !== first, 2000);
        tryVerify(() => rig.background().displayMode === nextMode, 2000);

        compare(first.displayMode, modeBefore, "outgoing scene took the next wallpaper's display mode");
        tryCompare(loader.item, "displayMode", nextMode);
        rig.destroy();
    }

    function test_rapid_switch_keeps_the_scene_that_is_on_screen() {
        const rig = _mkRigWithScene("111");
        const loader = _loader(rig);
        const first = loader.item;
        _playerOf(first).firstFrame();

        _switchTo(rig, "222");
        tryVerify(() => loader.item && loader.item !== first, 2000);
        const never = loader.item;              // never draws
        _switchTo(rig, "333");
        tryVerify(() => loader.item && loader.item !== never && loader.item !== first, 2000);
        // What the user sees is still the first scene, not a blank gap.
        verify(loader._outgoing === first);
        rig.destroy();
    }

    function test_same_wallpaper_path_change_swaps_in_place() {
        const rig = _mkRigWithScene("111");
        const loader = _loader(rig);
        const first = loader.item;
        rig.setConfig({ WallpaperSource: "/tmp/fakelib/steamapps/workshop/content/431960/111/other.pkg+scene" });
        wait(200);
        verify(loader.item === first, "a path change on the same workshop id must not rebuild");
        rig.destroy();
    }
}
