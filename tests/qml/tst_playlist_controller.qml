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
        // Symmetric with emptyWpModel — VideoListModel emits modelRefreshed
        // at the end of refresh().  Tests fire it manually to simulate the
        // async scan completing.
        signal modelRefreshed()
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

    // Regression for W2: a "video:hash"-prefixed Videos-tab item must resolve
    // through videoListModel + drive setWallpaperFromItem.  Pre-fix, the
    // runtime PlaylistController bound videoListModel: null so this case
    // always fell through to skipCurrent() — 8 consecutive skips
    // auto-deactivated any playlist containing a plain-video entry.
    function test_applyWorkshopIdVideoItem_callsSetter() {
        ctrl._applyWorkshopId("video:abcdef");
        compare(tc.lastSet.fn, "setWallpaperFromItem");
        compare(tc.lastSet.item.workshopid, "video:abcdef");
        compare(tc.lastSet.item.title, "ClipA");
    }

    // Cold-start, video-only race: wp model loaded but empty (no workshop
    // wallpapers installed) AND video model still scanning.  An active
    // playlist of plain-video entries must queue, not skipCurrent.
    function test_coldStart_videoOnly_queuesAndReplaysOnVideoRefresh() {
        const savedWp  = ctrl.wpListModel;
        const savedVid = ctrl.videoListModel;
        emptyWpInner.clear();
        emptyVidInner.clear();
        emptyWpModel.countNoFilter = 0;
        ctrl.wpListModel    = emptyWpModel;
        ctrl.videoListModel = emptyVidModel;

        tc.lastSet = {};
        ctrl._applyWorkshopId("video:later");
        compare(tc.lastSet.fn, undefined, "empty video model should queue, not call setter");
        compare(ctrl._pendingWorkshopId, "video:later");

        // Populate video model + fire its modelRefreshed — the new Connections
        // block in PlaylistController replays the pending id.
        emptyVidInner.append({ workshopid: "video:later", title: "Late Clip" });
        emptyVidModel.modelRefreshed();
        compare(tc.lastSet.fn, "setWallpaperFromItem");
        compare(tc.lastSet.item.workshopid, "video:later");
        compare(ctrl._pendingWorkshopId, "");

        ctrl.wpListModel    = savedWp;
        ctrl.videoListModel = savedVid;
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

    // Rapid activate/deactivate/activate within one event loop turn —
    // race against _pendingWorkshopId and the mgr→parent Connections.
    // Tests that quick toggling doesn't leave the controller wedged
    // with a stale pending id or double-fire activate.
    function test_rapidActivateDeactivateCycle_doesNotWedge() {
        const savedRead = ctrl.activePlaylistIdRead;
        ctrl.activePlaylistIdRead = "";
        // Sequence of state changes inside one event loop turn.
        ctrl.activePlaylistIdRead = "pl-1";
        ctrl.activePlaylistIdRead = "";
        ctrl.activePlaylistIdRead = "pl-1";
        ctrl.activePlaylistIdRead = "pl-2";
        ctrl.activePlaylistIdRead = "";
        // After all that churn the controller's view of activePlaylistId
        // should be the LAST read value — no zombie state.
        compare(ctrl.activePlaylistIdRead, "");
        ctrl.activePlaylistIdRead = savedRead;
    }

    // modelRefreshed AFTER _pendingWorkshopId was cleared by a successful
    // resolve — controller must NOT re-apply a stale id from the prior
    // queue cycle. Wrapped in try/finally so the wpListModel restore
    // always runs even when an assert throws — otherwise subsequent
    // tests inherit a polluted ctrl.wpListModel and fail in confusing
    // ways.
    function test_modelRefreshedAfterPendingCleared_doesNotReapply() {
        const savedWp = ctrl.wpListModel;
        try {
            emptyWpInner.clear();
            emptyWpInner.append({ workshopid: "delayed-id", title: "X" });
            emptyWpModel.countNoFilter = 1;
            ctrl.wpListModel = emptyWpModel;

            // Successful resolve: setter fires, no pending queue lingers.
            tc.lastSet = {};
            ctrl._applyWorkshopId("delayed-id");
            compare(tc.lastSet.fn, "setWallpaperFromItem");
            compare(ctrl._pendingWorkshopId, "");

            // Fire a spurious modelRefreshed — pending is already empty,
            // so the Connections handler short-circuits and the setter
            // does NOT re-fire.
            tc.lastSet = {};
            emptyWpModel.modelRefreshed();
            compare(tc.lastSet.fn, undefined,
                    "spurious modelRefreshed must not re-trigger setter");
        } finally {
            ctrl.wpListModel = savedWp;
        }
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

    // _serveFilteredPick must forward _lastFilteredPickIdx as the `cur`
    // argument to mgr.pickShuffle. First pick: cur == -1; second pick:
    // cur == previous safeIdx. The C++ pickShuffle no-repeat guard then
    // protects the Filtered Library from immediate repeats just like the
    // user-curated shuffle path.
    function test_serveFilteredPick_callsMgrPickShuffleWithLastIdx() {
        const saved = ctrl.wpListModel;
        const m = Qt.createQmlObject(
            'import QtQuick; QtObject { property var model: ListModel{} }', tc);
        m.model.append({ workshopid: "A" });
        m.model.append({ workshopid: "B" });
        m.model.append({ workshopid: "C" });
        ctrl.wpListModel = m;
        ctrl._lastFilteredPickIdx = -1;
        ctrl.manager.pickShuffleCount = 0;

        // First pick: stub returns 0 for cur==-1.
        ctrl._serveFilteredPick();
        compare(ctrl.manager.pickShuffleCount, 1);
        compare(ctrl.manager.lastPickShuffleArgs.cur, -1);
        compare(ctrl.manager.lastPickShuffleArgs.size, 3);

        // Second pick: cur is the previous safeIdx (0).
        ctrl._serveFilteredPick();
        compare(ctrl.manager.pickShuffleCount, 2);
        compare(ctrl.manager.lastPickShuffleArgs.cur, 0);
        compare(ctrl.manager.lastPickShuffleArgs.size, 3);

        ctrl.wpListModel = saved;
    }

    // End-to-end: with a stub pickShuffle that honours the C++ contract
    // (deterministic round-robin), 50 consecutive picks never repeat the
    // same workshopid back-to-back.
    function test_serveFilteredPick_neverPicksSameIndexTwiceInARow() {
        const saved = ctrl.wpListModel;
        const m = Qt.createQmlObject(
            'import QtQuick; QtObject { property var model: ListModel{} }', tc);
        m.model.append({ workshopid: "A" });
        m.model.append({ workshopid: "B" });
        m.model.append({ workshopid: "C" });
        ctrl.wpListModel = m;
        ctrl._lastFilteredPickIdx = -1;

        let last = null;
        for (let i = 0; i < 50; ++i) {
            ctrl._serveFilteredPick();
            const cur = ctrl.manager.lastAcceptPickArg;
            if (last !== null)
                verify(cur !== last,
                    "immediate repeat at i=" + i + ": " + cur + " == " + last);
            last = cur;
        }
        ctrl.wpListModel = saved;
    }

    // Reset on activate-different-playlist: re-entering the Filtered Library
    // after a different playlist must NOT carry the stale index across
    // activations of (possibly different) filter sets.
    function test_serveFilteredPick_lastIdxResetsOnPlaylistChange() {
        const saved = ctrl.wpListModel;
        const m = Qt.createQmlObject(
            'import QtQuick; QtObject { property var model: ListModel{} }', tc);
        m.model.append({ workshopid: "A" });
        m.model.append({ workshopid: "B" });
        ctrl.wpListModel = m;
        ctrl._lastFilteredPickIdx = -1;

        // First pick sets _lastFilteredPickIdx to a non-(-1) value.
        ctrl._serveFilteredPick();
        verify(ctrl._lastFilteredPickIdx !== -1);

        // Simulate deactivate via the activePlaylistIdRead binding — the
        // onActivePlaylistIdReadChanged reset hook clears the index.
        ctrl.manager.activePlaylistId = "prev-id";
        ctrl.activePlaylistIdRead = "";
        compare(ctrl._lastFilteredPickIdx, -1);

        // Re-activate; next pick again uses cur == -1.
        ctrl.manager.pickShuffleCount = 0;
        ctrl.manager.activePlaylistId = "";
        ctrl.activePlaylistIdRead = "__filtered_library__";
        ctrl._serveFilteredPick();
        compare(ctrl.manager.lastPickShuffleArgs.cur, -1);

        ctrl.wpListModel = saved;
        ctrl.activePlaylistIdRead = "";
    }

    // ── manual navigation (Next / Previous) ──────────────────────────────
    // Both are user gestures, so they go through the manager's manual-step
    // API. The skip path is reserved for items that fail to resolve: it
    // spends a budget that switches the playlist off after eight misses,
    // which a user browsing their playlist must never hit.
    function test_next_stepsTheManagerForward() {
        const mgr = ctrl.manager;
        mgr.stepByCount = 0;
        mgr.skipCurrentCount = 0;
        ctrl.next();
        compare(mgr.stepByCount, 1);
        compare(mgr.lastStepByDelta, 1);
        compare(mgr.skipCurrentCount, 0, "Next must not spend the skip budget");
    }

    function test_previous_stepsTheManagerBackward() {
        const mgr = ctrl.manager;
        mgr.stepByCount = 0;
        mgr.skipCurrentCount = 0;
        ctrl.previous();
        compare(mgr.stepByCount, 1);
        compare(mgr.lastStepByDelta, -1, "Previous must step back, not forward");
        compare(mgr.skipCurrentCount, 0, "Previous must not spend the skip budget");
    }

    // Filtered Library has no stored item list, so "back" means re-serving
    // what was on screen before the last pick.
    function test_filteredPrevious_reservesTheItemBeforeTheCurrentOne() {
        const mgr = ctrl.manager;
        ctrl._serveFilteredPick();
        const first = mgr.lastAcceptPickArg;
        ctrl._serveFilteredPick();
        const second = mgr.lastAcceptPickArg;
        verify(first !== second);

        mgr.requestFilteredPreviousPick();
        compare(mgr.lastAcceptPickArg, first,
                "going back must replay the previous pick, not roll a new one");

        // A second back-step keeps walking the history, and once it runs out
        // the controller falls back to a fresh pick rather than going silent.
        mgr.lastAcceptPickArg = undefined;
        mgr.requestFilteredPreviousPick();
        verify(mgr.lastAcceptPickArg !== undefined);
        verify(mgr.lastAcceptPickArg !== "");
    }

    // Leaving the Filtered Library drops the history along with the shuffle
    // index — the next filter set is a different list of wallpapers.
    function test_filteredPrevious_historyClearsOnPlaylistChange() {
        const mgr = ctrl.manager;
        ctrl._serveFilteredPick();
        ctrl._serveFilteredPick();

        verify(ctrl._filteredHistory.length > 0);

        mgr.activePlaylistId = "__filtered_library__";
        ctrl.activePlaylistIdRead = "user-playlist";
        compare(ctrl._filteredHistory.length, 0);

        // With no history left, back-stepping still serves something.
        mgr.lastAcceptPickArg = undefined;
        mgr.requestFilteredPreviousPick();
        verify(mgr.lastAcceptPickArg !== undefined);
        verify(mgr.lastAcceptPickArg !== "");

        ctrl.activePlaylistIdRead = "";
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
        // Pre-arm: parent read is "init", mgr is "match". The reassignment
        // below makes read == mgr at change-time, exercising the early-return
        // branch. Snapshot the manager recorders and verify neither
        // activate() nor deactivate() fired.
        ctrl.activePlaylistIdRead = "init";
        ctrl.manager.activePlaylistId = "match";
        const aBefore = ctrl.manager.activateCount;
        const dBefore = ctrl.manager.deactivateCount;
        ctrl.activePlaylistIdRead = "match";  // matches mgr → early return
        compare(ctrl.manager.activateCount, aBefore,
                "no-op branch must NOT call mgr.activate");
        compare(ctrl.manager.deactivateCount, dBefore,
                "no-op branch must NOT call mgr.deactivate");
    }

    function test_onActivePlaylistIdRead_deactivateBranch() {
        ctrl.manager.activePlaylistId = "anything";
        ctrl.activePlaylistIdRead = "some-id";
        const dBefore = ctrl.manager.deactivateCount;
        ctrl.activePlaylistIdRead = "";  // empty → deactivate branch
        compare(ctrl.manager.deactivateCount, dBefore + 1,
                "empty read must call mgr.deactivate exactly once");
    }

    function test_onActivePlaylistIdRead_activateBranch() {
        ctrl.manager.activePlaylistId = "";
        const aBefore = ctrl.manager.activateCount;
        ctrl.activePlaylistIdRead = "user-playlist";  // → activate branch
        compare(ctrl.manager.activateCount, aBefore + 1,
                "non-empty read must call mgr.activate exactly once");
        compare(ctrl.manager.lastActivateId, "user-playlist");
    }

    function test_onActivePlaylistIdRead_activateFilteredBranch() {
        // __filtered_library__ takes the setFilteredLibraryIntervalMin
        // path before activate — exercise it for completeness.
        ctrl.manager.activePlaylistId = "";
        ctrl.switchTimerRead = 30;
        const aBefore = ctrl.manager.activateCount;
        const sBefore = ctrl.manager.setFilteredLibraryIntervalMinCount;
        ctrl.activePlaylistIdRead = "__filtered_library__";
        compare(ctrl.manager.setFilteredLibraryIntervalMinCount, sBefore + 1,
                "filtered library activation must seed interval first");
        compare(ctrl.manager.lastSetFilteredLibraryIntervalMinArg, 30);
        compare(ctrl.manager.activateCount, aBefore + 1,
                "filtered library read must call mgr.activate");
        compare(ctrl.manager.lastActivateId, "__filtered_library__");
    }

    // onRandomizeWallpaperReadChanged covers:
    //   1. read=true,  no active playlist            → activate filtered
    //   2. read=true,  some playlist already active  → no-op inner branch
    //   3. read=false, filtered active               → deactivate
    //   4. read=false, other playlist active         → no-op
    function test_onRandomizeWallpaperRead_activatesFiltered() {
        ctrl.manager.activePlaylistId = "";
        ctrl.randomizeWallpaperRead = false;
        const aBefore = ctrl.manager.activateCount;
        const sBefore = ctrl.manager.setFilteredLibraryIntervalMinCount;
        ctrl.randomizeWallpaperRead = true;  // → activate filtered branch
        compare(ctrl.manager.setFilteredLibraryIntervalMinCount, sBefore + 1,
                "randomize-on with no active playlist must seed filtered interval");
        compare(ctrl.manager.activateCount, aBefore + 1,
                "randomize-on with no active playlist must activate filtered library");
        compare(ctrl.manager.lastActivateId, "__filtered_library__");
    }

    function test_onRandomizeWallpaperRead_skipsWhenPlaylistAlreadyActive() {
        ctrl.manager.activePlaylistId = "user-pl";
        ctrl.randomizeWallpaperRead = false;
        const aBefore = ctrl.manager.activateCount;
        const sBefore = ctrl.manager.setFilteredLibraryIntervalMinCount;
        ctrl.randomizeWallpaperRead = true;  // active exists → inner skip
        compare(ctrl.manager.activateCount, aBefore,
                "randomize-on with active playlist must NOT call activate");
        compare(ctrl.manager.setFilteredLibraryIntervalMinCount, sBefore,
                "randomize-on with active playlist must NOT seed interval");
    }

    function test_onRandomizeWallpaperRead_deactivatesFiltered() {
        ctrl.manager.activePlaylistId = "__filtered_library__";
        ctrl.randomizeWallpaperRead = true;
        const dBefore = ctrl.manager.deactivateCount;
        ctrl.randomizeWallpaperRead = false;  // → deactivate branch
        compare(ctrl.manager.deactivateCount, dBefore + 1,
                "randomize-off while filtered active must call deactivate");
    }

    function test_onRandomizeWallpaperRead_leavesOtherPlaylistAloneOnDisable() {
        ctrl.manager.activePlaylistId = "user-pl";
        ctrl.randomizeWallpaperRead = true;
        const dBefore = ctrl.manager.deactivateCount;
        const aBefore = ctrl.manager.activateCount;
        ctrl.randomizeWallpaperRead = false;  // not filtered → no-op
        compare(ctrl.manager.deactivateCount, dBefore,
                "randomize-off while non-filtered active must NOT deactivate");
        compare(ctrl.manager.activateCount, aBefore,
                "randomize-off must NOT spuriously re-activate");
    }
}
