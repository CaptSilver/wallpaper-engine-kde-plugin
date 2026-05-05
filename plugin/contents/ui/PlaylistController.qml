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
    property var wallpaperConfig: null  // wallpaper.configuration (or config.qml root)
    property var common:          null  // Common namespace (DI)
    property bool noRandomWhilePaused: false
    property bool desktopOk: true

    PlaylistManager {
        id: mgr
        onTick: function(workshopId) { root._applyWorkshopId(workshopId); }
        onRequestFilteredPick: { root._serveFilteredPick(); }
        onPersistFailed: function(reason) { console.warn("[playlist] persist failed:", reason); }
        onActivationFailed: function(id) { console.warn("[playlist] activation failed:", id); }
        onActivePlaylistIdChanged: {
            if (root.wallpaperConfig
                && root.wallpaperConfig.ActivePlaylistId !== mgr.activePlaylistId)
                root.wallpaperConfig.ActivePlaylistId = mgr.activePlaylistId;
        }
        onCurrentItemIndexChanged: {
            if (root.wallpaperConfig
                && root.wallpaperConfig.CurrentItemIndex !== mgr.currentItemIndex)
                root.wallpaperConfig.CurrentItemIndex = mgr.currentItemIndex;
        }
    }

    // Expose mgr for the editor pages
    readonly property alias manager: mgr

    function _resolveItem(workshopId) {
        if (!workshopId) return null;
        if (root.wpListModel && root.wpListModel.model) {
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

    function _applyWorkshopId(workshopId) {
        const item = _resolveItem(workshopId);
        if (!item) {
            console.warn("[playlist] item", workshopId, "not resolvable; skipping");
            mgr.skipCurrent();
            return;
        }
        if (!root.wallpaperConfig || !root.common) return;
        root.wallpaperConfig.WallpaperWorkShopId = item.workshopid;
        root.wallpaperConfig.WallpaperSource = root.common.packWallpaperSource(item);
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
        if (!root.wallpaperConfig) return;
        // Migration: RandomizeWallpaper=on AND no ActivePlaylistId yet → activate
        // the Filtered Library.
        if (root.wallpaperConfig.RandomizeWallpaper
            && !root.wallpaperConfig.ActivePlaylistId) {
            mgr.setFilteredLibraryIntervalMin(root.wallpaperConfig.SwitchTimer || 15);
            mgr.activate("__filtered_library__");
        } else if (root.wallpaperConfig.ActivePlaylistId) {
            // Re-activate a previously-active playlist on plasmashell startup.
            if (root.wallpaperConfig.ActivePlaylistId === "__filtered_library__")
                mgr.setFilteredLibraryIntervalMin(root.wallpaperConfig.SwitchTimer || 15);
            mgr.activate(root.wallpaperConfig.ActivePlaylistId);
        }
    }

    // Two-way bindings: SwitchTimer / RandomizeWallpaper toggles in Settings
    // mirror the Filtered Library state.
    Connections {
        target: root.wallpaperConfig
        ignoreUnknownSignals: true
        function onSwitchTimerChanged() {
            if (mgr.activePlaylistId === "__filtered_library__")
                mgr.setFilteredLibraryIntervalMin(root.wallpaperConfig.SwitchTimer || 15);
        }
        function onRandomizeWallpaperChanged() {
            if (root.wallpaperConfig.RandomizeWallpaper) {
                if (!mgr.activePlaylistId) {
                    mgr.setFilteredLibraryIntervalMin(root.wallpaperConfig.SwitchTimer || 15);
                    mgr.activate("__filtered_library__");
                }
            } else if (mgr.activePlaylistId === "__filtered_library__") {
                mgr.deactivate();
            }
        }
    }
}
