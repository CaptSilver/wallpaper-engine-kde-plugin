// Integration test for the filter ⇄ playlist interaction. Uses real
// WallpaperListModel + real PlaylistController + real PlaylistsPage to
// catch the class of bug fixed in b282df7: lookups that iterated the
// filtered `model` ListModel instead of the unfiltered source returned
// numeric workshopids for playlist items the user filtered off the
// Wallpapers tab — and PlaylistController silently skipped them during
// playback.
//
// Pre-fix this test would fail at the "filtered-out lookup" assertion
// for both _resolveItem and _resolveItemTitle.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as PluginUi
import "../../plugin/contents/ui/page" as Pages
import "../../plugin/contents/ui/js/utils.mjs" as Utils

TestCase {
    id: tc
    name: "FilterPlaylistIntegration"
    width: 800; height: 600
    when: windowShown

    // ── Mock pyext / readfile so the real WallpaperListModel can complete a
    // refresh cycle without touching disk. The per-item readfile returns a
    // JSON blob whose `title`/`type`/`contentrating` are derived from the
    // requested path so we can build a heterogeneous source in one call.
    function _thenable(value) {
        return {
            then: function(onResolve) {
                if (onResolve) {
                    const r = onResolve(value);
                    return r && r.then ? r : tc._thenable(r);
                }
                return tc._thenable(value);
            },
            catch: function() { return tc._thenable(value); },
        };
    }

    // Per-wallpaper metadata. Keyed by workshopid.
    property var _wpMeta: ({
        "1001": { title: "Wallpaper One",   type: "scene", contentrating: "Everyone" },
        "1002": { title: "Wallpaper Two",   type: "scene", contentrating: "Mature"   },
        "1003": { title: "Wallpaper Three", type: "scene", contentrating: "Everyone" },
    })

    function _readfileFor(path) {
        // path looks like "/wp/1002/project.json"
        const m = String(path).match(/\/(\d+)\/project\.json$/);
        const meta = m ? tc._wpMeta[m[1]] : null;
        return tc._thenable(meta ? JSON.stringify(meta)
                                 : '{"general":{"playlists":[]}}');
    }

    // pyext stub — WallpaperListModel makes a bare `pyext.get_folder_list`
    // reference inside refresh(). With enabled=true (needed so filterStr
    // changes actually refilter), refresh fires on construction and on
    // every enabledChanged. The stub returns an empty folder so refresh
    // is a no-op without crashing; tests then drive loadFolderLists
    // directly with the data they want.
    property var pyext: ({
        get_folder_list: function(dir, opts) {
            return tc._thenable({ folder: dir, items: [] });
        }
    })

    PluginUi.WallpaperListModel {
        id: wpModel
        enabled: true   // required: filterStrChanged is gated on enabled
        workshopDirs: ["/wp"]
        globalConfigPath: "/wp/global.json"
        readfile: tc._readfileFor
        // production-side refresh() seeds root.playlists; we drive
        // loadFolderLists directly, so mirror that init here.
        Component.onCompleted: { wpModel.playlists = {}; }
    }

    QtObject {
        id: fakeCommon
        function packWallpaperSource(item) { return "src-" + item.workshopid; }
    }

    property var lastSet: ({})

    PluginUi.PlaylistController {
        id: ctrl
        wpListModel: wpModel
        common: fakeCommon
        activePlaylistIdRead: ""
        currentItemIndexRead: 0
        randomizeWallpaperRead: false
        switchTimerRead: 15
        setActivePlaylistId: function(id) { tc.lastSet = { fn: "setActivePlaylistId", id: id }; }
        setCurrentItemIndex: function(idx) { tc.lastSet = { fn: "setCurrentItemIndex", idx: idx }; }
        setWallpaperFromItem: function(item) {
            tc.lastSet = { fn: "setWallpaperFromItem", item: item };
        }
    }

    Pages.PlaylistsPage {
        id: page
        anchors.fill: parent
        manager: ctrl.manager
        wpListModel: wpModel
        cfg_ActivePlaylistId: ""
    }

    // Load the three wallpapers once and wait for the unfiltered source to
    // populate. countNoFilter is bumped in filterToList's .then which fires
    // after folderWorker.model is fully assembled, so it's the right gate.
    function _loadSource() {
        wpModel.loadFolderLists([{
            folder: "/wp",
            items: [
                { name: "1001", mtime: 1 },
                { name: "1002", mtime: 2 },
                { name: "1003", mtime: 3 },
            ],
        }]);
        tryVerify(function() { return wpModel.countNoFilter === 3; },
                  2000, "wpModel source never finished loading");
    }

    function init() {
        tc.lastSet = {};
        wpModel.filterStr = "";  // default filter (Mature=0)
    }

    // ── Assertions ────────────────────────────────────────────────────────────

    // With the default filter (Mature=0), wallpaper 1002 is excluded from
    // wpModel.model but still present in the unfiltered source. The fixed
    // _resolveItem must return it via findItem, NOT skip it.
    function test_resolveItemFindsFilteredOutWallpaper() {
        _loadSource();
        // Sanity: default filter excludes 1002 (Mature) from the public model.
        let inFiltered = false;
        for (let i = 0; i < wpModel.model.count; ++i)
            if (wpModel.model.get(i).workshopid === "1002") inFiltered = true;
        verify(! inFiltered, "default filter should exclude the Mature wallpaper");

        const it = ctrl._resolveItem("1002");
        verify(it !== null, "_resolveItem returned null for a filtered-out playlist item");
        compare(it.workshopid, "1002");
        compare(it.title, "Wallpaper Two");
    }

    // PlaylistsPage queue title for a filtered-out item must still render
    // the real title — the bug was rendering the numeric workshopid.
    function test_playlistsPageTitleFromUnfilteredSource() {
        _loadSource();
        compare(page._resolveItemTitle("1002"), "Wallpaper Two");
    }

    // Drive a real playlist through PlaylistController and verify a tick
    // for a filtered-out item still ends in setWallpaperFromItem instead
    // of being silently skipped.
    function test_applyWorkshopIdFiltersOutItemStillCyclesIt() {
        _loadSource();
        ctrl._applyWorkshopId("1002");
        compare(tc.lastSet.fn, "setWallpaperFromItem");
        compare(tc.lastSet.item.workshopid, "1002");
        compare(tc.lastSet.item.title, "Wallpaper Two");
    }

    // Flip the filter to also exclude Scene. Now ALL three wallpapers are
    // filtered out — but the playlist must still resolve them via findItem.
    // This is the worst case (filter excludes everything) and proves
    // _modelsAreEmpty's countNoFilter heuristic doesn't mistake it for
    // "source still loading". Build the full filter array from
    // Common.filterModel so the length matches and we only flip the
    // chips we mean to flip — getValueArray() falls back to defaults
    // silently if the array is short.
    // filterStr format is char-per-chip with no separators
    // (strToIntArray in utils.mjs maps each char back to a digit).
    function _buildFilterStr(overrides) {
        const fm = PluginUi.Common.filterModel;
        let s = "";
        for (let i = 0; i < fm.count; ++i) {
            const v = overrides.hasOwnProperty(i) ? overrides[i] : fm.get(i).def;
            s += String(v);
        }
        return s;
    }

    function test_aggressiveFilterDoesNotBreakResolve() {
        _loadSource();
        // Common.filterModel indices: 2 = Scene chip. Disable it: every
        // loaded wallpaper has type="scene", so the filtered model goes
        // empty while folderWorker.model still holds all three.
        wpModel.filterStr = _buildFilterStr({ 2: 0 });
        tryCompare(wpModel.model, "count", 0, 2000);
        compare(wpModel.countNoFilter, 3,
                "unfiltered source size must stay 3 regardless of filter");

        const it = ctrl._resolveItem("1001");
        verify(it !== null, "even with empty filtered model, findItem must hit");
        compare(it.workshopid, "1001");
    }
}
