// End-to-end integration test for the playlist activation/deactivation +
// wallpaper-pick + Apply flow. Simulates the user's exact sequence and
// verifies cfg_* and the (faked) wallpaperConfiguration values at each
// step. If a future regression breaks the chain, this test catches it
// without needing a journal dump.
//
// We can't run the real Plasma config dialog from qmltestrunner — it
// requires a live ContainmentInterface. Instead we construct the same
// shape: a wallpaperConfiguration JS object, cfg_* properties tracked
// separately, and our PlaylistController wired with the same setters
// config.qml uses at runtime.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as PluginUi

TestCase {
    id: tc
    name: "PlaylistIntegration"
    width: 200; height: 200
    when: windowShown

    // ── Fake plasmoid environment ─────────────────────────────────────────────
    property var wallpaperConfiguration: ({
        WallpaperSource: "src-A",
        WallpaperWorkShopId: "A",
        ActivePlaylistId: "",
        CurrentItemIndex: 0,
        RandomizeWallpaper: false,
        SwitchTimer: 15,
    })

    // Dialog cfg_* aliases. Plasma's KCM normally initializes these from the
    // plasmoid config at dialog open and tracks pending diffs.
    property string cfg_WallpaperSource: ""
    property string cfg_WallpaperWorkShopId: ""

    function _openDialog() {
        // Mirror Plasma: cfg_* snapshot from current plasmoid config.
        tc.cfg_WallpaperSource     = tc.wallpaperConfiguration.WallpaperSource;
        tc.cfg_WallpaperWorkShopId = tc.wallpaperConfiguration.WallpaperWorkShopId;
    }

    // Plasma's Apply-enabled check. True when cfg_* differs from
    // wallpaperConfiguration. A function (not a binding) because
    // wallpaperConfiguration is a `property var` and JS dot-access on it
    // doesn't propagate to QML's reactive system the way a real
    // KConfigPropertyMap does in production.
    function applyEnabled() {
        return tc.cfg_WallpaperSource     !== tc.wallpaperConfiguration.WallpaperSource ||
               tc.cfg_WallpaperWorkShopId !== tc.wallpaperConfiguration.WallpaperWorkShopId;
    }

    function _clickApply() {
        if (!applyEnabled()) return false;
        // saveConfig: flush cfg_* into wallpaperConfiguration.
        tc.wallpaperConfiguration.WallpaperSource     = tc.cfg_WallpaperSource;
        tc.wallpaperConfiguration.WallpaperWorkShopId = tc.cfg_WallpaperWorkShopId;
        return true;
    }

    // Mirror WallpaperPage.onItemClicked — only writes cfg_*.
    function _userPicksWallpaper(item) {
        tc.cfg_WallpaperSource     = "src-" + item.workshopid;
        tc.cfg_WallpaperWorkShopId = item.workshopid;
    }

    QtObject {
        id: fakeWpModel
        property var model: ListModel {
            id: wpm
            Component.onCompleted: {
                wpm.append({ workshopid: "A", title: "A" });
                wpm.append({ workshopid: "B", title: "B" });
                wpm.append({ workshopid: "C", title: "C" });
                wpm.append({ workshopid: "D", title: "D" });
            }
        }
    }

    QtObject {
        id: fakeCommon
        function packWallpaperSource(item) { return "src-" + item.workshopid; }
    }

    // ── Two PlaylistController instances mirroring config.qml + main.qml ─────
    PluginUi.PlaylistController {
        id: dialogCtrl
        wpListModel: fakeWpModel
        common: fakeCommon
        activePlaylistIdRead: tc.wallpaperConfiguration.ActivePlaylistId
        currentItemIndexRead: tc.wallpaperConfiguration.CurrentItemIndex
        randomizeWallpaperRead: tc.wallpaperConfiguration.RandomizeWallpaper
        switchTimerRead: tc.wallpaperConfiguration.SwitchTimer

        // Live writes to wallpaperConfiguration for activation state.
        setActivePlaylistId: function(id) {
            tc.wallpaperConfiguration.ActivePlaylistId = id;
        }
        setCurrentItemIndex: function(idx) {
            tc.wallpaperConfiguration.CurrentItemIndex = idx;
        }
        // No-op — runtime is responsible for the actual wallpaper change.
        setWallpaperFromItem: function(item) { }
    }

    PluginUi.PlaylistController {
        id: runtimeCtrl
        wpListModel: fakeWpModel
        common: fakeCommon
        activePlaylistIdRead: tc.wallpaperConfiguration.ActivePlaylistId
        currentItemIndexRead: tc.wallpaperConfiguration.CurrentItemIndex
        randomizeWallpaperRead: tc.wallpaperConfiguration.RandomizeWallpaper
        switchTimerRead: tc.wallpaperConfiguration.SwitchTimer

        // Runtime writes plasmoid config directly (live) when its mgr ticks.
        setActivePlaylistId: function(id) {
            tc.wallpaperConfiguration.ActivePlaylistId = id;
        }
        setCurrentItemIndex: function(idx) {
            tc.wallpaperConfiguration.CurrentItemIndex = idx;
        }
        setWallpaperFromItem: function(item) {
            tc.wallpaperConfiguration.WallpaperWorkShopId = item.workshopid;
            tc.wallpaperConfiguration.WallpaperSource     = fakeCommon.packWallpaperSource(item);
        }
    }

    function init() {
        tc.wallpaperConfiguration.WallpaperSource     = "src-A";
        tc.wallpaperConfiguration.WallpaperWorkShopId = "A";
        tc.wallpaperConfiguration.ActivePlaylistId    = "";
        tc.wallpaperConfiguration.CurrentItemIndex    = 0;
        tc.cfg_WallpaperSource     = "";
        tc.cfg_WallpaperWorkShopId = "";
        // Reset both manager states.
        dialogCtrl.manager.deactivate();
        runtimeCtrl.manager.deactivate();
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    function test_applyAfterPickingDifferentWallpaper() {
        _openDialog();
        compare(tc.cfg_WallpaperSource, "src-A"); // initial snapshot

        // User picks B
        _userPicksWallpaper({ workshopid: "B" });
        compare(tc.cfg_WallpaperSource, "src-B");
        verify(applyEnabled());

        // Apply
        verify(_clickApply());
        compare(tc.wallpaperConfiguration.WallpaperSource, "src-B");
        verify(!applyEnabled()); // cfg_ now matches plasmoid
    }

    function test_applyDisabledWhenPickingCurrentWallpaper() {
        _openDialog();
        // User picks A again (same as current)
        _userPicksWallpaper({ workshopid: "A" });
        verify(!applyEnabled());
    }

    function test_activateThenDeactivateThenPickDifferent() {
        _openDialog();
        // Setup: playlist with B and C
        const id = dialogCtrl.manager.createPlaylist("P");
        dialogCtrl.manager.addItem(id, "B");
        dialogCtrl.manager.addItem(id, "C");

        // Drive activation: dialog ctrl sets ActivePlaylistId via setter
        // (tests the dialog → wallpaperConfiguration → runtime ctrl chain)
        dialogCtrl.setActivePlaylistId(id);
        // Runtime ctrl's onActivePlaylistIdReadChanged fires → runtime mgr.activate
        // Runtime mgr emits tick(B) → setWallpaperFromItem callback writes to wcfg
        // (in tests, the stubbed mgr doesn't actually emit tick, so we drive it manually)
        runtimeCtrl._applyWorkshopId("B");
        compare(tc.wallpaperConfiguration.WallpaperSource, "src-B");
        compare(tc.wallpaperConfiguration.WallpaperWorkShopId, "B");

        // User clicks Deactivate
        dialogCtrl.setActivePlaylistId("");
        // wallpaperConfiguration.ActivePlaylistId is now ""

        // The visible wallpaper is still B (last cycled). cfg_ in dialog
        // is still "src-A" (unchanged from open — dialog's setWallpaperFromItem
        // is a no-op so the cycle didn't taint it).
        compare(tc.cfg_WallpaperSource, "src-A");
        compare(tc.wallpaperConfiguration.WallpaperSource, "src-B");
        // Apply diff? cfg_(A) vs wcfg(B) → DIFFER → Apply enabled
        verify(applyEnabled());

        // User explicitly picks D
        _userPicksWallpaper({ workshopid: "D" });
        compare(tc.cfg_WallpaperSource, "src-D");
        verify(applyEnabled()); // still enabled

        // Apply
        verify(_clickApply());
        compare(tc.wallpaperConfiguration.WallpaperSource, "src-D");
    }

    function test_activateDeactivatePickOriginalApplyEnabled() {
        // The "user wants to go back to original" case.
        _openDialog();
        const id = dialogCtrl.manager.createPlaylist("P");
        dialogCtrl.manager.addItem(id, "B");

        dialogCtrl.setActivePlaylistId(id);
        runtimeCtrl._applyWorkshopId("B");
        // visible wallpaper is now B. plasmoid wcfg.WallpaperSource = src-B.

        dialogCtrl.setActivePlaylistId(""); // deactivate

        // User picks A (their original)
        _userPicksWallpaper({ workshopid: "A" });
        compare(tc.cfg_WallpaperSource, "src-A");
        // wcfg.WallpaperSource is still src-B → Apply enabled
        verify(applyEnabled());

        verify(_clickApply());
        compare(tc.wallpaperConfiguration.WallpaperSource, "src-A");
    }

    function test_dialogSetWallpaperFromItem_isNoOp() {
        // Confirms the recent fix: dialog's setWallpaperFromItem must NOT
        // write cfg_* — that previously confused Apply tracking.
        _openDialog();
        compare(tc.cfg_WallpaperSource, "src-A");

        // Drive dialog ctrl's _applyWorkshopId — would have written cfg_*
        // pre-fix.
        dialogCtrl._applyWorkshopId("C");

        // cfg_ stays at original; only the runtime would write wcfg.
        compare(tc.cfg_WallpaperSource, "src-A");
    }
}
