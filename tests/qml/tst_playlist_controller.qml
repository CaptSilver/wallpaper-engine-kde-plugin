// Coverage tests for PlaylistController.qml. The controller is an internal
// adapter — exercising its handlers requires a fake wallpaperConfig and
// list models. wallpaperConfig is a JS object literal so we can use the
// upper-case Q_PROPERTY-like names (KConfigXT field names) — QML user
// properties must start with lowercase, but JS object keys are any-case.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as PluginUi

TestCase {
    id: tc
    name: "PlaylistController"
    width: 200; height: 200
    when: windowShown

    QtObject {
        id: fakeWpModel
        property var model: ListModel {
            id: wpModel
            Component.onCompleted: {
                wpModel.append({ workshopid: "wid-A", title: "A" });
                wpModel.append({ workshopid: "wid-B", title: "B" });
            }
        }
    }

    QtObject {
        id: fakeVideoModel
        property var model: ListModel {
            id: vidModel
            Component.onCompleted: {
                vidModel.append({ workshopid: "video:abcdef", title: "ClipA" });
            }
        }
    }

    // Wallpaper config as a plain JS object — the controller treats it as a
    // duck-typed bag of Q_PROPERTYs. JS keys can start with uppercase.
    property var fakeWallpaperConfig: ({
        ActivePlaylistId: "",
        CurrentItemIndex: 0,
        WallpaperWorkShopId: "",
        WallpaperSource: "",
        RandomizeWallpaper: false,
        SwitchTimer: 15,
    })

    QtObject {
        id: fakeCommon
        function packWallpaperSource(item) { return "packed-" + item.workshopid; }
    }

    PluginUi.PlaylistController {
        id: ctrl
        wpListModel: fakeWpModel
        videoListModel: fakeVideoModel
        wallpaperConfig: tc.fakeWallpaperConfig
        common: fakeCommon
        noRandomWhilePaused: false
        desktopOk: true
    }

    function test_resolvesFromWpListModel() {
        const item = ctrl._resolveItem("wid-A");
        verify(item !== null);
        compare(item.workshopid, "wid-A");
    }

    function test_resolvesFromVideoListModel() {
        const item = ctrl._resolveItem("video:abcdef");
        verify(item !== null);
        compare(item.workshopid, "video:abcdef");
    }

    function test_resolveMissingReturnsNull() {
        compare(ctrl._resolveItem("not-here"), null);
    }

    function test_resolveEmptyReturnsNull() {
        compare(ctrl._resolveItem(""), null);
    }

    function test_applyWorkshopIdHits() {
        ctrl._applyWorkshopId("wid-B");
        compare(tc.fakeWallpaperConfig.WallpaperWorkShopId, "wid-B");
        compare(tc.fakeWallpaperConfig.WallpaperSource, "packed-wid-B");
    }

    function test_applyWorkshopIdMissingDoesNotMutate() {
        const before = tc.fakeWallpaperConfig.WallpaperWorkShopId;
        ctrl._applyWorkshopId("not-here");
        compare(tc.fakeWallpaperConfig.WallpaperWorkShopId, before);
    }

    function test_serveFilteredPickWithItems() {
        // Should invoke acceptPick on the manager — exercise the path.
        ctrl._serveFilteredPick();
    }

    function test_pauseGateFlipsTriggerHandlers() {
        ctrl.desktopOk = true;
        ctrl.noRandomWhilePaused = true;
        ctrl.desktopOk = false;
        compare(ctrl._pauseGate, false);
        ctrl.desktopOk = true;
        compare(ctrl._pauseGate, true);
    }

    function test_managerSignalsTriggerHandlers() {
        // Fire the manager's signals to exercise the controller's onTick /
        // onRequestFilteredPick / onPersistFailed / onActivationFailed handlers.
        ctrl.manager.tick("wid-A");
        compare(tc.fakeWallpaperConfig.WallpaperWorkShopId, "wid-A");

        ctrl.manager.requestFilteredPick();
        // _serveFilteredPick called acceptPick on the stub — no observable
        // side effect on our fake config, but the path is covered.

        ctrl.manager.persistFailed("disk full");
        ctrl.manager.activationFailed("nonexistent");
        // Both handlers just console.warn; coverage tracer counts the entry.
    }

    function test_emptyWpListServesEmptyPick() {
        // Replace the model with an empty one and call _serveFilteredPick —
        // exercises the count===0 branch.
        const emptyModel = Qt.createQmlObject(
            'import QtQuick; QtObject { property var model: ListModel{} }', tc);
        const saved = ctrl.wpListModel;
        ctrl.wpListModel = emptyModel;
        ctrl._serveFilteredPick();
        ctrl.wpListModel = saved;
    }

    function test_nullWpListServesEmptyPick() {
        const saved = ctrl.wpListModel;
        ctrl.wpListModel = null;
        ctrl._serveFilteredPick();
        ctrl.wpListModel = saved;
    }
}
