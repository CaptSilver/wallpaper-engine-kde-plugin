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
        // Use a read that doesn't match the failed id so the self-heal
        // branch in onActivationFailed stays inert here; the dedicated
        // self-heal tests below cover the matching case.
        ctrl.activePlaylistIdRead = "current-active";
        ctrl.manager.activationFailed("nonexistent");
    }

    // Self-heal: when activation fails for the very playlist cfg points
    // at, the controller clears cfg so subsequent plasmashell launches
    // don't keep retrying a dead id (e.g., deleted-but-still-pinned
    // playlist, hand-edited playlists.json).
    function test_onActivationFailed_clearsCfgIfReadMatchesFailedId() {
        ctrl.activePlaylistIdRead = "dead-id";
        tc.lastSet = {};
        ctrl.manager.activationFailed("dead-id");
        compare(tc.lastSet.fn, "setActivePlaylistId");
        compare(tc.lastSet.id, "");
    }

    // Transient races: another playlist's activation failed while a
    // different one is active. Leave cfg alone — don't clobber the
    // current active state on unrelated failure signals.
    function test_onActivationFailed_leavesCfgAloneIfReadDiffers() {
        ctrl.activePlaylistIdRead = "current-active";
        tc.lastSet = {};
        ctrl.manager.activationFailed("transient-other");
        compare(tc.lastSet.fn, undefined);
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
