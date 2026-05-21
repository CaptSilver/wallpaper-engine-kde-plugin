import QtQuick
import QtTest
import Helpers 1.0
import "../../plugin/contents/ui" as Plugin

// Phase 2 broad coverage: main.qml's child components driven end-to-end through
// the real root under ScreenRig. Config inputs go via rig.setConfig() (whole-object
// reassign so bindings re-fire); runtime drivers use the genuinely-reactive stub
// QObjects (DataSource.data, TasksModel._windows). The default backend is InfoShow
// (no source) whose play()/pause() are no-ops, so autoPause() runs clean.
TestCase {
    id: tc
    name: "Main_Components"
    when: windowShown
    width: 400; height: 300

    Component { id: rigComp; ScreenRig {} }

    // ── PowerSource: battery discharge -> reqPause -> background.ok ──────────
    function test_powerSource_discharging_pauses_via_ok() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        tryVerify(() => rig.powerSource() !== null, 2000);
        rig.setConfig({ PauseOnBatPower: true });
        const ps = rig.powerSource();
        const ds = rig._find(ps, o => typeof o.connectSource === "function" && typeof o.data !== "undefined");
        verify(ds !== null);

        // Discharging on battery -> reqPause true -> background.ok false.
        ds.data = { "Battery": { "Has Battery": true, "State": "Discharging", "Percent": 80 } };
        tryVerify(() => ps.reqPause === true, 2000, "PowerSource.reqPause did not engage");
        tryVerify(() => rig.background().ok === false, 2000, "background.ok did not drop on battery pause");

        // Back on AC -> reqPause false -> background.ok recovers true. Proves the
        // binding is reactive (re-evaluates on st_battery_state change), not a
        // one-way latch — the user-visible resume-on-replug behaviour.
        ds.data = { "Battery": { "Has Battery": true, "State": "Charging", "Percent": 80 } };
        tryVerify(() => ps.reqPause === false, 2000, "PowerSource.reqPause did not clear on AC");
        tryVerify(() => rig.background().ok === true, 2000, "background.ok did not recover on AC");

        rig.destroy();
    }

    // ── Item 01: percent-threshold arm of reqPause through background.ok ────
    function test_powerSource_lowPercent_pauses_via_ok() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        tryVerify(() => rig.powerSource() !== null, 2000);
        // PauseOnBatPower stays false; only the percent threshold should drive it.
        rig.setConfig({ PauseBatPercent: 20 });
        const ps = rig.powerSource();
        const ds = rig._find(ps, o => typeof o.connectSource === "function" && typeof o.data !== "undefined");
        verify(ds !== null);

        // Below threshold -> reqPause true -> ok false.
        ds.data = { "Battery": { "Has Battery": true, "State": "Charging", "Percent": 10 } };
        tryVerify(() => ps.reqPause === true, 2000, "low-percent reqPause did not engage");
        tryVerify(() => rig.background().ok === false, 2000, "background.ok did not drop on low charge");

        // Above threshold -> reqPause false -> ok true.
        ds.data = { "Battery": { "Has Battery": true, "State": "Charging", "Percent": 50 } };
        tryVerify(() => ps.reqPause === false, 2000, "reqPause did not clear above threshold");
        tryVerify(() => rig.background().ok === true, 2000, "background.ok did not recover above threshold");

        rig.destroy();
    }

    // ── WindowModel: a non-minimized window in Any mode -> reqPause -> ok ────
    function test_windowModel_pauses_via_ok() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        tryVerify(() => rig.windowModel() !== null, 2000);
        rig.setConfig({ PauseMode: Plugin.Common.PauseMode.Any });
        const wm = rig.windowModel();
        const tm = rig._find(wm, o => typeof o._windows !== "undefined");
        verify(tm !== null);
        tm._windows = [{
            isActive: false, isMaximized: false, isFullScreen: false,
            isMinimized: false, activities: [], appName: "win1",
        }];
        wm.updateWindowsinfo();
        const tt = rig._find(wm, o => typeof o.start === "function" && o.interval == 100);
        if (tt) tt.triggered();
        tryVerify(() => wm.reqPause === true, 2000, "WindowModel.reqPause did not engage");
        tryVerify(() => rig.background().ok === false, 2000, "background.ok did not drop on window pause");
        rig.destroy();
    }

    // ── PlaylistController: config wiring (active id + reload seq) ───────────
    function test_playlistController_reflects_config() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0, 0, 1920, 1080) });
        tryVerify(() => rig.playlistController() !== null, 2000);
        const pc = rig.playlistController();
        rig.setConfig({ ActivePlaylistId: "pl-1" });
        tryCompare(pc, "activePlaylistIdRead", "pl-1");      // config -> controller
        rig.setConfig({ PlaylistsReloadSeq: 1 });
        tryCompare(pc, "playlistsReloadSeqRead", 1);         // reload-seq watch path
        rig.destroy();
    }
}
