// Reproduces the user-reported flow: activate → deactivate → user picks
// wallpaper → cfg_WallpaperSource should change so Apply enables.
//
// Notes on stub behaviour: in qmltestrunner, the QML stub of
// PlaylistManager (tests/qml/_stubs/.../PlaylistManager.qml) does not
// actually fire `tick` from `activate()`. So instead of relying on the
// real C++ tick behaviour, we drive the controller's internal hooks
// directly (`_applyWorkshopId`) and the parent-side cfg_ setters
// (matching what config.qml + WallpaperPage do at runtime).
import QtQuick
import QtTest

import "../../plugin/contents/ui" as PluginUi

TestCase {
    id: tc
    name: "DeactivateThenPick"
    width: 200; height: 200
    when: windowShown

    property var fakeWallpaperConfig: ({
        ActivePlaylistId: "",
        CurrentItemIndex: 0,
    })

    property string cfg_WallpaperSource: ""
    property string cfg_WallpaperWorkShopId: ""

    QtObject {
        id: fakeWpModel
        property var model: ListModel {
            id: wpm
            Component.onCompleted: {
                wpm.append({ workshopid: "111", title: "First",  path: "/p1", file: "scene.json", type: "scene" });
                wpm.append({ workshopid: "222", title: "Second", path: "/p2", file: "scene.json", type: "scene" });
                wpm.append({ workshopid: "333", title: "Third",  path: "/p3", file: "scene.json", type: "scene" });
            }
        }
    }

    QtObject {
        id: fakeCommon
        function packWallpaperSource(item) { return "packed-" + item.workshopid; }
    }

    PluginUi.PlaylistController {
        id: ctrl
        wpListModel: fakeWpModel
        common: fakeCommon
        noRandomWhilePaused: false
        desktopOk: true

        activePlaylistIdRead: tc.fakeWallpaperConfig.ActivePlaylistId
        currentItemIndexRead: tc.fakeWallpaperConfig.CurrentItemIndex
        randomizeWallpaperRead: false
        switchTimerRead: 15

        setActivePlaylistId: function(id) {
            tc.fakeWallpaperConfig.ActivePlaylistId = id;
        }
        setCurrentItemIndex: function(idx) {
            tc.fakeWallpaperConfig.CurrentItemIndex = idx;
        }
        setWallpaperFromItem: function(item) {
            // Mirrors config.qml: only cfg_* writes for wallpaper fields.
            tc.cfg_WallpaperWorkShopId = item.workshopid;
            tc.cfg_WallpaperSource     = fakeCommon.packWallpaperSource(item);
        }
    }

    // Mirrors WallpaperPage.onItemClicked
    function userPicksWallpaper(item) {
        tc.cfg_WallpaperSource = fakeCommon.packWallpaperSource(item);
        tc.cfg_WallpaperWorkShopId = item.workshopid;
    }

    function init() {
        tc.fakeWallpaperConfig.ActivePlaylistId = "";
        tc.fakeWallpaperConfig.CurrentItemIndex = 0;
        tc.cfg_WallpaperSource = "";
        tc.cfg_WallpaperWorkShopId = "";
    }

    function test_applyWorkshopIdFiresSetWallpaperFromItem() {
        // Drive the resolution path directly — this is what mgr.tick →
        // controller.onTick → _applyWorkshopId does at runtime.
        ctrl._applyWorkshopId("111");
        compare(tc.cfg_WallpaperWorkShopId, "111");
        compare(tc.cfg_WallpaperSource, "packed-111");
    }

    function test_userPickAfterCycle_changesCfg() {
        // Simulate the full flow without relying on stubbed mgr.activate.
        // 1. Cycle to "111" (as if playlist activated)
        ctrl._applyWorkshopId("111");
        compare(tc.cfg_WallpaperSource, "packed-111");

        // 2. "Deactivate" — fakeWallpaperConfig.ActivePlaylistId stays "",
        //    no further mgr ticks fire.

        // 3. User clicks "333" in the grid.
        userPicksWallpaper({ workshopid: "333" });

        // 4. cfg_WallpaperSource SHOULD be packed-333 — Apply diff vs
        //    plasmoid config (which is still packed-111, what the
        //    runtime persisted) is non-zero → Apply enabled.
        compare(tc.cfg_WallpaperSource, "packed-333");
        compare(tc.cfg_WallpaperWorkShopId, "333");
    }

    function test_userPickSameAsCycled_yieldsZeroDiff() {
        // Edge case: cycled to "111", then user picks "111" — cfg matches
        // what the runtime has, Apply correctly stays disabled.
        ctrl._applyWorkshopId("111");
        compare(tc.cfg_WallpaperSource, "packed-111");

        userPicksWallpaper({ workshopid: "111" });
        // cfg_WallpaperSource stayed at packed-111 — no change, no diff.
        compare(tc.cfg_WallpaperSource, "packed-111");
    }

    function test_modelEmptyDefersResolution() {
        // When wpListModel is empty (race at startup), the workshop ID
        // queues into _pendingWorkshopId rather than burning the skip
        // budget. This is the cold-start fix.
        const emptyModel = Qt.createQmlObject(
            'import QtQuick; QtObject { property var model: ListModel{} }', tc);
        const saved = ctrl.wpListModel;
        ctrl.wpListModel = emptyModel;

        ctrl._applyWorkshopId("999");
        compare(ctrl._pendingWorkshopId, "999");
        compare(tc.cfg_WallpaperSource, ""); // not applied yet

        ctrl.wpListModel = saved;
    }
}
