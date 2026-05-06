// Coverage tests for PlaylistController.qml. The controller no longer holds
// a wallpaperConfig reference — it takes plain reads + setter callbacks
// from the parent. Tests provide stub readers/writers to exercise the
// resolve / pause / migration paths.
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

    QtObject {
        id: fakeCommon
        function packWallpaperSource(item) { return "packed-" + item.workshopid; }
    }

    // Captured writes from the controller's setter callbacks.
    property var lastSet: ({})

    PluginUi.PlaylistController {
        id: ctrl
        wpListModel: fakeWpModel
        videoListModel: fakeVideoModel
        common: fakeCommon
        noRandomWhilePaused: false
        desktopOk: true

        activePlaylistIdRead: ""
        currentItemIndexRead: 0
        randomizeWallpaperRead: false
        switchTimerRead: 15

        setActivePlaylistId: function(id) { tc.lastSet = { fn: "setActivePlaylistId", id: id }; }
        setCurrentItemIndex: function(idx) { tc.lastSet = { fn: "setCurrentItemIndex", idx: idx }; }
        setWallpaperFromItem: function(item) { tc.lastSet = { fn: "setWallpaperFromItem", item: item }; }
    }

    function init() { tc.lastSet = {}; }

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

    function test_applyWorkshopIdCallsSetter() {
        ctrl._applyWorkshopId("wid-B");
        compare(tc.lastSet.fn, "setWallpaperFromItem");
        compare(tc.lastSet.item.workshopid, "wid-B");
    }

    function test_applyWorkshopIdMissingDoesNotCallSetter() {
        ctrl._applyWorkshopId("not-here");
        // Setter was not called for missing items; lastSet stays empty.
        compare(tc.lastSet.fn, undefined);
    }

    function test_serveFilteredPickWithItems() {
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
        ctrl.manager.tick("wid-A");
        compare(tc.lastSet.fn, "setWallpaperFromItem");

        ctrl.manager.requestFilteredPick();
        ctrl.manager.persistFailed("disk full");
        ctrl.manager.activationFailed("nonexistent");
    }

    function test_emptyWpListServesEmptyPick() {
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
