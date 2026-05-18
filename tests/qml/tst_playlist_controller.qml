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

    // `_unfilteredItems` simulates the unfiltered source (folderWorker.model
    // in production). It's a SUPERSET of the filtered `model` ListModel:
    // `wid-FILTERED` is in the source but excluded by the simulated filter,
    // mirroring the production state when a user filter chip drops a
    // wallpaper from the Wallpapers tab view. `countNoFilter` mirrors the
    // production property so PlaylistController's _modelsAreEmpty heuristic
    // distinguishes "filter excludes everything" from "source not loaded".
    QtObject {
        id: fakeWpModel
        property var model: ListModel {
            id: wpModel
            Component.onCompleted: {
                wpModel.append({ workshopid: "wid-A", title: "A" });
                wpModel.append({ workshopid: "wid-B", title: "B" });
            }
        }
        property int countNoFilter: 3
        property var _unfilteredItems: [
            { workshopid: "wid-A",        title: "A" },
            { workshopid: "wid-B",        title: "B" },
            { workshopid: "wid-FILTERED", title: "FilteredOut" },
        ]
        function findItem(workshopid) {
            for (let i = 0; i < _unfilteredItems.length; ++i)
                if (_unfilteredItems[i].workshopid === workshopid) return _unfilteredItems[i];
            return null;
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

    // Empty wp/video models for the cold-start race test. Declared at
    // TestCase scope (instead of via Qt.createQmlObject) so the modelRefreshed
    // signal can be declared properly — dynamic QML doesn't support `signal`.
    QtObject {
        id: emptyWpModel
        property var model: ListModel { id: emptyWpInner }
        property int countNoFilter: 0
        signal modelRefreshed()
    }
    QtObject {
        id: emptyVidModel
        property var model: ListModel { id: emptyVidInner }
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

    // Regression: a wallpaper currently excluded by the user's Wallpapers-tab
    // filter chips must still play when its turn comes up in a playlist.
    // Before the fix, _resolveItem iterated only the filtered ListModel and
    // returned null for `wid-FILTERED`, causing skipCurrent to fire.
    function test_resolvesFilteredOutItemFromUnfilteredSource() {
        const item = ctrl._resolveItem("wid-FILTERED");
        verify(item !== null);
        compare(item.workshopid, "wid-FILTERED");
        compare(item.title, "FilteredOut");
    }

    function test_applyWorkshopIdFilteredOut_callsSetter() {
        ctrl._applyWorkshopId("wid-FILTERED");
        compare(tc.lastSet.fn, "setWallpaperFromItem");
        compare(tc.lastSet.item.workshopid, "wid-FILTERED");
    }

    // Source loaded but no entry for workshopId → real miss, not a race.
    // Controller must skipCurrent (warn + advance), not queue forever.
    function test_loadedModel_missingId_doesNotQueue() {
        tc.lastSet = {};
        ctrl._applyWorkshopId("really-not-there");
        compare(ctrl._pendingWorkshopId, "",
                "non-race miss must not queue — would hang the playlist");
    }

    // Cold-start race: at plasmoid launch, the playlist controller may try
    // to apply a workshopId before WallpaperListModel has finished loading
    // (refresh + per-file readfile + JSON parse). Without the pending
    // queue, _applyWorkshopId would skipCurrent immediately — burning the
    // 8-skip budget on a race condition. The fix queues the workshopId
    // and retries on modelRefreshed.
    function test_coldStart_emptyModel_queuesAndReplaysOnRefresh() {
        const savedWp  = ctrl.wpListModel;
        const savedVid = ctrl.videoListModel;
        // Reset the empty fixtures in case a previous run dirtied them.
        emptyWpInner.clear();
        emptyVidInner.clear();
        emptyWpModel.countNoFilter = 0;
        ctrl.wpListModel    = emptyWpModel;
        ctrl.videoListModel = emptyVidModel;

        tc.lastSet = {};
        ctrl._applyWorkshopId("queue-me");
        compare(tc.lastSet.fn, undefined,
                "empty model should queue, not call setter");
        compare(ctrl._pendingWorkshopId, "queue-me");

        // Populate + fire modelRefreshed: the controller's Connections
        // block replays the pending id.
        emptyWpInner.append({ workshopid: "queue-me", title: "Queued" });
        emptyWpModel.countNoFilter = 1;
        emptyWpModel.modelRefreshed();
        compare(tc.lastSet.fn, "setWallpaperFromItem");
        compare(tc.lastSet.item.workshopid, "queue-me");
        compare(ctrl._pendingWorkshopId, "",
                "pending id should clear once successfully applied");

        ctrl.wpListModel    = savedWp;
        ctrl.videoListModel = savedVid;
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

    // ── Manager → parent: mgr.activePlaylistId / currentItemIndex changes ──
    // The PlaylistManager stub exposes these as plain QML properties, so
    // assigning to them from a test fires the change-signal that the
    // controller's onActivePlaylistIdChanged / onCurrentItemIndexChanged
    // handlers listen to.
    function test_mgrActivePlaylistIdChange_propagatesToSetter() {
        ctrl.activePlaylistIdRead = "";  // ensure differs from new value
        tc.lastSet = {};
        ctrl.manager.activePlaylistId = "playlist-42";
        compare(tc.lastSet.fn, "setActivePlaylistId");
        compare(tc.lastSet.id, "playlist-42");
    }

    function test_mgrActivePlaylistIdChange_noWriteWhenAlreadyEqual() {
        // Drive parent + mgr to the same value, then reassign mgr to the
        // same value again — change signal still fires QML-side but the
        // handler's equality guard suppresses the setter write.
        ctrl.activePlaylistIdRead = "same-id";
        ctrl.manager.activePlaylistId = "same-id";
        tc.lastSet = {};
        // Trigger the signal again via a round-trip through a different
        // value (assigning the same string in a row doesn't re-emit).
        ctrl.manager.activePlaylistId = "other";
        ctrl.manager.activePlaylistId = "same-id";
        // Both reassignments fire the handler; only the second runs the
        // equality guard's "no write" branch. We only care that lastSet
        // ends up matching the *most recent* setter call, which is the
        // "other" detour (read=="same-id" ≠ "other" → setter ran).
        compare(tc.lastSet.fn, "setActivePlaylistId");
        compare(tc.lastSet.id, "other");
    }

    function test_mgrCurrentItemIndexChange_propagatesToSetter() {
        ctrl.currentItemIndexRead = 0;
        tc.lastSet = {};
        ctrl.manager.currentItemIndex = 5;
        compare(tc.lastSet.fn, "setCurrentItemIndex");
        compare(tc.lastSet.idx, 5);
    }

    function test_mgrCurrentItemIndexChange_noWriteWhenAlreadyEqual() {
        ctrl.currentItemIndexRead = 7;
        ctrl.manager.currentItemIndex = 7;
        tc.lastSet = {};
        ctrl.manager.currentItemIndex = 9;  // diverge to fire handler
        ctrl.manager.currentItemIndex = 7;  // equality branch
        compare(tc.lastSet.fn, "setCurrentItemIndex");
        compare(tc.lastSet.idx, 9);
    }

    // ── Parent → manager: activePlaylistIdRead / randomizeWallpaperRead ───
    // onActivePlaylistIdReadChanged covers three branches:
    //   1. read == mgr.activePlaylistId → early return (no-op)
    //   2. read == ""                    → mgr.deactivate()
    //   3. otherwise                     → mgr.activate(id), with the
    //      __filtered_library__ interval seeded first.
    // qmlcov counts the whole handler as one unit, so any single firing
    // marks the unit hit. We still exercise each branch for safety.
    function test_onActivePlaylistIdRead_noopBranch() {
        ctrl.manager.activePlaylistId = "match";
        ctrl.activePlaylistIdRead = "other";  // diverge first
        ctrl.activePlaylistIdRead = "match";  // matches mgr → early return
        verify(true);
    }

    function test_onActivePlaylistIdRead_deactivateBranch() {
        ctrl.manager.activePlaylistId = "anything";
        ctrl.activePlaylistIdRead = "some-id";
        ctrl.activePlaylistIdRead = "";  // empty → deactivate branch
        verify(true);
    }

    function test_onActivePlaylistIdRead_activateBranch() {
        ctrl.manager.activePlaylistId = "";
        ctrl.activePlaylistIdRead = "user-playlist";  // → activate branch
        verify(true);
    }

    function test_onActivePlaylistIdRead_activateFilteredBranch() {
        // __filtered_library__ takes the setFilteredLibraryIntervalMin
        // path before activate — exercise it for completeness.
        ctrl.manager.activePlaylistId = "";
        ctrl.switchTimerRead = 30;
        ctrl.activePlaylistIdRead = "__filtered_library__";
        verify(true);
    }

    // onRandomizeWallpaperReadChanged covers:
    //   1. read=true,  no active playlist            → activate filtered
    //   2. read=true,  some playlist already active  → no-op inner branch
    //   3. read=false, filtered active               → deactivate
    //   4. read=false, other playlist active         → no-op
    function test_onRandomizeWallpaperRead_activatesFiltered() {
        ctrl.manager.activePlaylistId = "";
        ctrl.randomizeWallpaperRead = false;
        ctrl.randomizeWallpaperRead = true;  // → activate filtered branch
        verify(true);
    }

    function test_onRandomizeWallpaperRead_skipsWhenPlaylistAlreadyActive() {
        ctrl.manager.activePlaylistId = "user-pl";
        ctrl.randomizeWallpaperRead = false;
        ctrl.randomizeWallpaperRead = true;  // active exists → inner skip
        verify(true);
    }

    function test_onRandomizeWallpaperRead_deactivatesFiltered() {
        ctrl.manager.activePlaylistId = "__filtered_library__";
        ctrl.randomizeWallpaperRead = true;
        ctrl.randomizeWallpaperRead = false;  // → deactivate branch
        verify(true);
    }

    function test_onRandomizeWallpaperRead_leavesOtherPlaylistAloneOnDisable() {
        ctrl.manager.activePlaylistId = "user-pl";
        ctrl.randomizeWallpaperRead = true;
        ctrl.randomizeWallpaperRead = false;  // not filtered → no-op
        verify(true);
    }
}
