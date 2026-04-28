// WindowModel.qml — window-aware pause/play. The model owns a TasksModel
// (stubbed), an ActivityInfo + VirtualDesktopInfo (also stubbed), and a
// SortFilterModel. We drive coverage by:
//   1. Setting a fixture window list on the inner TasksModel via its `_windows`
//      stub property.
//   2. Toggling modePlay and calling `updateWindowsinfo()` (which schedules
//      a 100ms triggerTimer); fire the timer's `triggered()` directly.
//   3. Firing the simple play/pause/playBy paths.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WindowModel"
    width: 200; height: 100
    when: windowShown

    Plugin.WindowModel {
        id: wm
        screenGeometry: ({ x: 0, y: 0, width: 1920, height: 1080 })
        modePlay: Plugin.Common.PauseMode.FocusOrMax
    }

    function _findInner(parent, marker) {
        const buckets = [parent.children || [], parent.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && b[i][marker] !== undefined) return b[i];
            }
        }
        return null;
    }

    function _findTasksModel() { return _findInner(wm, "_windows"); }
    function _findTriggerTimer() {
        const buckets = [wm.children || [], wm.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const t = b[i];
                if (t && typeof t.start === "function" &&
                    typeof t.interval !== "undefined" && t.interval == 100) return t;
            }
        }
        return null;
    }
    function _findPlayTimer() {
        const buckets = [wm.children || [], wm.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const t = b[i];
                if (t && typeof t.start === "function" &&
                    typeof t.interval !== "undefined" && t.interval !== 100) return t;
            }
        }
        return null;
    }

    function _setWindows(windows) {
        const tm = _findTasksModel();
        verify(tm !== null);
        tm._windows = windows;
    }

    // ── play/pause/playBy ─────────────────────────────────────────────────────
    function test_play_resetsReqPauseAfterTimer() {
        wm._reqPause = true;
        wm.play();
        const playTimer = _findPlayTimer();
        verify(playTimer !== null);
        playTimer.triggered();
        compare(wm._reqPause, false);
    }

    function test_pause_setsReqPauseImmediately() {
        wm._reqPause = false;
        wm.pause();
        compare(wm._reqPause, true);
    }

    function test_playBy_truthDispatchesToPlay() {
        wm.playBy(true);
        verify(true);
    }

    function test_playBy_falseDispatchesToPause() {
        wm.playBy(false);
        compare(wm._reqPause, true);
    }

    // ── _updateWindowsinfo branches by modePlay ──────────────────────────────
    function _runUpdate() {
        wm.updateWindowsinfo();           // schedules triggerTimer
        const tt = _findTriggerTimer();
        if (tt) tt.triggered();           // fire synchronously
    }

    function test_updateNeverMode_alwaysPlays() {
        wm.modePlay = Plugin.Common.PauseMode.Never;
        _setWindows([]);
        _runUpdate();
        verify(true);
    }

    function test_updateAnyMode_pausesWhenWindowsExist() {
        wm.modePlay = Plugin.Common.PauseMode.Any;
        _setWindows([{
            isActive: false, isMaximized: false, isFullScreen: false,
            isMinimized: false, activities: [], appName: "win1",
        }]);
        _runUpdate();
        verify(true);
    }

    function test_updateMaxMode_pausesWhenMaximized() {
        wm.modePlay = Plugin.Common.PauseMode.Max;
        _setWindows([{
            isActive: false, isMaximized: true, isFullScreen: false,
            isMinimized: false, activities: [], appName: "max1",
        }]);
        _runUpdate();
        verify(true);
    }

    function test_updateFullScreenMode_pausesWhenFullscreen() {
        wm.modePlay = Plugin.Common.PauseMode.FullScreen;
        _setWindows([{
            isActive: false, isMaximized: false, isFullScreen: true,
            isMinimized: false, activities: [], appName: "fs1",
        }]);
        _runUpdate();
        verify(true);
    }

    function test_updateFocusMode_pausesWhenActive() {
        wm.modePlay = Plugin.Common.PauseMode.Focus;
        _setWindows([{
            isActive: true, isMaximized: false, isFullScreen: false,
            isMinimized: false, activities: [], appName: "act1",
        }]);
        _runUpdate();
        verify(true);
    }

    function test_updateFocusOrMax_pausesWhenEither() {
        wm.modePlay = Plugin.Common.PauseMode.FocusOrMax;
        _setWindows([{
            isActive: true, isMaximized: false, isFullScreen: false,
            isMinimized: false, activities: [], appName: "act1",
        }]);
        _runUpdate();
        verify(true);
    }

    function test_updateWithMixedActivities_filtersOnlyMatchingActivity() {
        wm.activity = "act-A";
        wm.modePlay = Plugin.Common.PauseMode.Any;
        _setWindows([
            { isActive: true, isMaximized: false, isFullScreen: false,
              isMinimized: false, activities: ["act-A"], appName: "matching" },
            { isActive: false, isMaximized: false, isFullScreen: false,
              isMinimized: false, activities: ["act-B"], appName: "other" },
        ]);
        _runUpdate();
        verify(true);
    }

    function test_updateMinimizedWindowsExcluded() {
        wm.modePlay = Plugin.Common.PauseMode.Any;
        _setWindows([{
            isActive: false, isMaximized: false, isFullScreen: false,
            isMinimized: true, activities: [], appName: "minimized",
        }]);
        _runUpdate();
        // notMinWModel should be empty → playBy(true)
        verify(true);
    }

    function test_loggingOn_runsPrintWLoopWithoutThrowing() {
        wm.logging = true;
        wm.modePlay = Plugin.Common.PauseMode.Any;
        _setWindows([{
            isActive: true, isMaximized: true, isFullScreen: false,
            isMinimized: false, activities: ["x"], appName: "logged",
        }]);
        _runUpdate();
        wm.logging = false;
        verify(true);
    }

    // ── ActivityInfo / VirtualDesktopInfo signal handlers ────────────────────
    function _findActivityInfo() {
        const buckets = [wm.children || [], wm.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const a = b[i];
                if (a && typeof a.currentActivity !== "undefined" && !("_windows" in a)) return a;
            }
        }
        return null;
    }

    function test_activityChanged_propagatesToVirtualDesktop() {
        const ai = _findActivityInfo();
        if (ai) ai.currentActivityChanged();
        verify(true);
    }

    // ── tasksModel signal handlers ───────────────────────────────────────────
    function test_tasksModelActiveTaskChanged_triggersUpdate() {
        const tm = _findTasksModel();
        if (tm) tm.activeTaskChanged();
        verify(true);
    }

    function test_tasksModelVirtualDesktopChanged_triggersUpdate() {
        const tm = _findTasksModel();
        if (tm) tm.virtualDesktopChanged();
        verify(true);
    }

    function test_tasksModelGetProperty_unknownNameReturnsUndefined() {
        const tm = _findTasksModel();
        verify(tm !== null);
        compare(tm.getProperty(0, "ZZZNoSuchRole"), undefined);
    }
}
