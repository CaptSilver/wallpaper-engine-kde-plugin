// Bridges PlaylistManager tick events to wallpaper.configuration changes.
// Resolves workshop_id → wallpaper item via the parent's wpListModel /
// videoListModel; calls PlaylistManager.skipCurrent() on miss; serves
// PlaylistManager.requestFilteredPick by sampling the live filtered model.
//
// Owns the migration step: on first run with RandomizeWallpaper=true and
// no ActivePlaylistId set, activates the built-in Filtered Library.
// Subsequent runs are no-ops (PlaylistManager's playlists.json existence
// gate is the one-shot trigger).
import QtQuick
import com.github.captsilver.wallpaperEngineKde

Item {
    id: root

    // Inputs (set by parent — main.qml or config.qml)
    property var wpListModel:    null   // WallpaperListModel
    property var videoListModel: null   // VideoListModel
    property var common:          null  // Common namespace (DI)
    property bool noRandomWhilePaused: false
    property bool desktopOk: true

    // Reads — parent supplies plain values rather than the config object,
    // because main.qml's `wallpaper.configuration` and config.qml's `root`
    // expose the same fields under different names (ActivePlaylistId vs
    // cfg_ActivePlaylistId). Centralising read/write through the parent
    // lets each context do the right thing without leaking config-shape
    // into the controller.
    property string activePlaylistIdRead: ""
    property int    currentItemIndexRead: 0
    property bool   randomizeWallpaperRead: false
    property int    switchTimerRead: 15

    // Writes — parent provides setters. Setters are responsible for
    // routing the value to the correct config field in their scope.
    property var setActivePlaylistId: function(id) { }
    property var setCurrentItemIndex: function(idx) { }
    property var setWallpaperFromItem: function(item) { } // applies WallpaperSource + WallpaperWorkShopId

    PlaylistManager {
        id: mgr
        onTick: function(workshopId) { root._applyWorkshopId(workshopId); }
        onRequestFilteredPick: { root._serveFilteredPick(); }
        onPersistFailed: function(reason) { console.warn("[playlist] persist failed:", reason); }
        onActivationFailed: function(id) {
            console.warn("[playlist] activation failed:", id);
            // Self-heal: if cfg points at the failed id (deleted playlist,
            // hand-edited playlists.json, dead migration leftover), clear it
            // so the next plasmashell launch doesn't keep retrying — and so
            // the dialog UI reflects "no playlist active" instead of a stale
            // selection. Only clear when read matches the failed id; a
            // transient races against a different active playlist must leave
            // the current state alone.
            if (root.activePlaylistIdRead === id)
                root.setActivePlaylistId("");
        }
        onActivePlaylistIdChanged: {
            console.warn("[WEK-DIAG ctrl mgrIdChanged]",
                "mgr.activeId:", mgr.activePlaylistId,
                "read:", root.activePlaylistIdRead);
            if (root.activePlaylistIdRead !== mgr.activePlaylistId)
                root.setActivePlaylistId(mgr.activePlaylistId);
        }
        onCurrentItemIndexChanged: {
            if (root.currentItemIndexRead !== mgr.currentItemIndex)
                root.setCurrentItemIndex(mgr.currentItemIndex);
        }
    }

    // Expose mgr for the editor pages
    readonly property alias manager: mgr

    function _resolveItem(workshopId) {
        if (!workshopId) return null;
        // Prefer the unfiltered source via findItem(): the user's filter
        // chips on the Wallpapers tab must not silently drop playlist items
        // from playback. Without this, a playlist of "all artists" with the
        // filter set to "solo only" would skip every group wallpaper.
        if (root.wpListModel && typeof root.wpListModel.findItem === "function") {
            const it = root.wpListModel.findItem(workshopId);
            if (it) return it;
        } else if (root.wpListModel && root.wpListModel.model) {
            // Fallback for fakes/tests that don't implement findItem.
            const m = root.wpListModel.model;
            for (let i = 0; i < m.count; ++i) {
                const it = m.get(i);
                if (it.workshopid === workshopId) return it;
            }
        }
        if (root.videoListModel && root.videoListModel.model) {
            const m = root.videoListModel.model;
            for (let i = 0; i < m.count; ++i) {
                const it = m.get(i);
                if (it.workshopid === workshopId) return it;
            }
        }
        return null;
    }

    // wpListModel loads asynchronously (pyext.readfile + JSON parse per
    // wallpaper). When this controller activates a playlist at startup —
    // either from Component.onCompleted or onActivePlaylistIdReadChanged
    // firing on a freshly-loaded plasmoid config — the model may still be
    // empty. _resolveItem returning null and falling through to skipCurrent
    // would burn the 8-skip budget on a race condition before the model is
    // even ready. Instead, queue the workshopId and retry once
    // modelRefreshed fires.
    property string _pendingWorkshopId: ""

    function _modelsAreEmpty() {
        // For wp, use countNoFilter (the UNFILTERED source size) so a strict
        // filter that happens to exclude every wallpaper isn't mistaken for
        // "model still loading". If the fake/test object doesn't expose
        // countNoFilter, fall back to the filtered-model count.
        const wp = root.wpListModel;
        const wpEmpty = !wp
                     || (typeof wp.countNoFilter === "number"
                            ? wp.countNoFilter === 0
                            : (!wp.model || wp.model.count === 0));
        const vidEmpty = !root.videoListModel || !root.videoListModel.model
                      || root.videoListModel.model.count === 0;
        return wpEmpty && vidEmpty;
    }

    function _applyWorkshopId(workshopId) {
        const item = _resolveItem(workshopId);
        if (!item) {
            if (_modelsAreEmpty()) {
                console.warn("[WEK-DIAG ctrl] _applyWorkshopId queuing pending=", workshopId);
                root._pendingWorkshopId = workshopId;
                return;
            }
            console.warn("[playlist] item", workshopId, "not resolvable; skipping");
            mgr.skipCurrent();
            return;
        }
        const replayed = root._pendingWorkshopId === workshopId;
        console.warn("[WEK-DIAG ctrl] _applyWorkshopId →setWallpaperFromItem wid=",
            workshopId, "replayedFromPending=", replayed);
        root._pendingWorkshopId = "";
        root.setWallpaperFromItem(item);
    }

    Connections {
        target: root.wpListModel
        ignoreUnknownSignals: true
        function onModelRefreshed() {
            if (root._pendingWorkshopId) {
                console.warn("[WEK-DIAG ctrl] modelRefreshed → replay pending=",
                    root._pendingWorkshopId);
                root._applyWorkshopId(root._pendingWorkshopId);
            }
        }
    }

    function _serveFilteredPick() {
        if (!root.wpListModel || !root.wpListModel.model) {
            mgr.acceptPick("");
            return;
        }
        const m = root.wpListModel.model;
        if (m.count === 0) { mgr.acceptPick(""); return; }
        const idx = Math.floor(Math.random() * m.count);
        const safeIdx = Math.min(idx, m.count - 1);
        mgr.acceptPick(m.get(safeIdx).workshopid);
    }

    // Pause hook
    property bool _pauseGate: !(root.noRandomWhilePaused && !root.desktopOk)
    on_PauseGateChanged: {
        if (_pauseGate) mgr.resumeTicks();
        else            mgr.pauseTicks();
    }

    Component.onCompleted: {
        // Migration: RandomizeWallpaper=on AND no ActivePlaylistId yet → activate
        // the Filtered Library.
        if (root.randomizeWallpaperRead && !root.activePlaylistIdRead) {
            mgr.setFilteredLibraryIntervalMin(root.switchTimerRead || 15);
            mgr.activate("__filtered_library__");
        } else if (root.activePlaylistIdRead) {
            // Re-activate previously-active playlist on plasmashell startup.
            if (root.activePlaylistIdRead === "__filtered_library__")
                mgr.setFilteredLibraryIntervalMin(root.switchTimerRead || 15);
            mgr.activate(root.activePlaylistIdRead);
        }
    }

    // Live propagation: when the parent's activePlaylistIdRead changes (e.g.
    // because the config dialog wrote cfg_ActivePlaylistId and plasmoid
    // config sync'd it through to wallpaper.configuration), drive the
    // underlying manager to match. Without this, hitting "Activate" in the
    // config dialog updates plasmoid config but the runtime controller's
    // manager stays inactive — wallpapers don't cycle.
    onActivePlaylistIdReadChanged: {
        console.warn("[WEK-DIAG ctrl readChanged]",
            "read:", root.activePlaylistIdRead,
            "mgr.activeId:", mgr.activePlaylistId);
        if (root.activePlaylistIdRead === mgr.activePlaylistId) return;
        if (root.activePlaylistIdRead === "") {
            mgr.deactivate();
        } else {
            if (root.activePlaylistIdRead === "__filtered_library__")
                mgr.setFilteredLibraryIntervalMin(root.switchTimerRead || 15);
            mgr.activate(root.activePlaylistIdRead);
        }
    }

    // Re-arm Filtered Library when SwitchTimer or RandomizeWallpaper change.
    onSwitchTimerReadChanged: {
        if (mgr.activePlaylistId === "__filtered_library__")
            mgr.setFilteredLibraryIntervalMin(root.switchTimerRead || 15);
    }
    onRandomizeWallpaperReadChanged: {
        if (root.randomizeWallpaperRead) {
            if (!mgr.activePlaylistId) {
                mgr.setFilteredLibraryIntervalMin(root.switchTimerRead || 15);
                mgr.activate("__filtered_library__");
            }
        } else if (mgr.activePlaylistId === "__filtered_library__") {
            mgr.deactivate();
        }
    }
}
