import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    name: "Backend_Mpv"
    width: 200; height: 100
    when: windowShown

    BackgroundFake { id: background }

    // loadInfoShow recorder — the Mpv watchdog handler calls
    // `videoItem.parent.loadInfoShow(...)` when libmpv fails to produce
    // a frame within 15s. Mpv's parent is this TestCase, so wiring a
    // function here lets us observe the watchdog firing the InfoShow path.
    property int    loadInfoShowCount: 0
    property string lastLoadInfoMsg:   ""
    function loadInfoShow(msg) {
        loadInfoShowCount += 1;
        lastLoadInfoMsg    = msg;
    }

    Backend.Mpv {
        id: mpv
        source: "stub://video.mp4"
    }

    function test_backendNameSetByCompleted() {
        compare(background.nowBackend, "mpv");
    }

    function test_play_pause_doNotThrow() {
        // play() forwards to player.play() (Mpv.qml:95); pause() starts
        // pauseTimer (no immediate player.pause), so only play increments
        // the counter here. The pauseTimer handler is exercised separately.
        const p = _findMpvPlayer();
        const n = p.playCount;
        mpv.play();
        compare(p.playCount, n + 1);
        mpv.pause();
        // pause() does NOT call player.pause() directly — it starts a
        // 200ms pauseTimer whose onTriggered does so. So playCount must
        // be unchanged and pauseCount must still be its prior value.
        compare(p.playCount, n + 1);
    }

    // The wallpaper settings hide per-wallpaper properties on video
    // wallpapers because this wrapper has nowhere to put them — mpv plays a
    // file, there is no shader uniform or script behind it. Pin the absence:
    // whoever adds a consumer here has to go re-enable the controls too.
    function test_userPropertiesReachNothingOnTheVideoPath() {
        const p = _findMpvPlayer();
        verify(p !== null);
        compare(typeof mpv.userPropsJson, "undefined",
                "the mpv wrapper exposes no user-property surface");
        const properties = p.setPropertyCount;
        const commands   = p.commandCount;
        background.userPropsJson = '{"schemecolor":"0.13 0.21 0.34"}';
        compare(p.setPropertyCount, properties);
        compare(p.commandCount, commands);
    }

    function test_getMouseTargetReturnsUndefined() {
        // Mpv backend explicitly does not return a mouse target.
        compare(mpv.getMouseTarget(), undefined);
    }

    function test_displayModeBranches() {
        // onDisplayModeChanged calls player.setProperty('keepaspect', …)
        // and player.setProperty('panscan', …) per branch (Mpv.qml:18-29).
        // The Mpv stub records lastSetProperty {name, val} on every call,
        // so we can assert the panscan value the wrapper computes for
        // each DisplayMode (panscan is set last, so lastSetProperty
        // reflects it). videoItem.displayMode is bound to
        // background.displayMode (Mpv.qml:9) so reassignment alone
        // fires onDisplayModeChanged — no explicit emit needed.
        const p = _findMpvPlayer();
        const cases = [
            { mode: Plugin.Common.DisplayMode.Crop,   panscan: 1.0, keepaspect: true  },
            { mode: Plugin.Common.DisplayMode.Aspect, panscan: 0.0, keepaspect: true  },
            { mode: Plugin.Common.DisplayMode.Scale,  panscan: 0.0, keepaspect: false },
        ];
        for (const c of cases) {
            const n = p.setPropertyCount;
            background.displayMode = c.mode;
            // Two setProperty calls per branch — keepaspect then panscan.
            compare(p.setPropertyCount, n + 2);
            compare(p.lastSetProperty.name, "panscan");
            compare(p.lastSetProperty.val,  c.panscan);
        }
    }

    function test_statsToggleFires() {
        // onStatsChanged emits player.command(["script-binding","stats/display-stats-toggle"])
        // unconditionally (Mpv.qml:45-47). videoItem.stats is bound to
        // background.mpvStats, so toggling the source propagates and
        // auto-emits the handler — no explicit emit needed.
        const p = _findMpvPlayer();
        const n = p.commandCount;
        background.mpvStats = !background.mpvStats;
        compare(p.commandCount, n + 1);
        compare(p.lastCommand[0], "script-binding");
        compare(p.lastCommand[1], "stats/display-stats-toggle");
    }

    function test_videoRateChangedSetsSpeedProperty() {
        // onVideoRateChanged forwards to player.setProperty('speed', videoRate)
        // (Mpv.qml:49). videoRate is bound to background.speed, so the
        // assignment propagates and auto-fires the handler.
        const p = _findMpvPlayer();
        const n = p.setPropertyCount;
        background.speed = 2.5;
        compare(p.setPropertyCount, n + 1);
        compare(p.lastSetProperty.name, "speed");
        compare(p.lastSetProperty.val,  2.5);
    }

    function _findMpvPlayer() {
        const buckets = [mpv.children || [], mpv.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && typeof b[i].setProperty === "function" &&
                    typeof b[i].command === "function") return b[i];
            }
        }
        return null;
    }

    function test_playerFirstFrame_routesToBackground() {
        // Mpv.qml uses a Connections block (with `ignoreUnknownSignals: true`)
        // to listen for the player's firstFrame signal and forward it via
        // background.sig_backendFirstFrame('mpv') (Mpv.qml:63-65). The
        // BackgroundFake records hits via firstFrameCount + lastFirstFrameName.
        const player = _findMpvPlayer();
        verify(player !== null);
        const n = background.firstFrameCount;
        player.firstFrame();
        compare(background.firstFrameCount, n + 1);
        compare(background.lastFirstFrameName, "mpv");
    }

    // loadWatchdog Timer onTriggered@79 — the 15s fallback that surfaces
    // a missing-frame failure to InfoShow when libmpv silently can't
    // produce the first frame. Find by its interval (15000) and fire
    // triggered() directly. The handler calls
    // `videoItem.parent.loadInfoShow(msg)` when the parent exposes it —
    // this TestCase declares loadInfoShow above so the routed call is
    // observable via loadInfoShowCount + lastLoadInfoMsg.
    function test_loadWatchdog_triggerRunsBody() {
        function findWatchdog(parent) {
            const buckets = [parent.children || [], parent.data || []];
            for (const b of buckets) {
                for (let i = 0; i < b.length; i++) {
                    const t = b[i];
                    if (t && typeof t.start === "function" &&
                        typeof t.interval !== "undefined" &&
                        t.interval === 15000) return t;
                }
            }
            return null;
        }
        const wd = findWatchdog(mpv);
        verify(wd !== null);
        const n = loadInfoShowCount;
        wd.triggered();
        compare(loadInfoShowCount, n + 1);
        // Production now assembles a trimmed "MPV produced no frame within
        // 15s." message — the immediate-failure path (sourceLoadFailed)
        // owns the "may be unsupported or missing" diagnostic, so the
        // watchdog only reports the silent-hang case it actually catches.
        verify(lastLoadInfoMsg.indexOf("no frame") !== -1);
    }

    function test_pauseTimerTriggeredEventuallyPausesPlayer() {
        // pause() starts pauseTimer (interval 200ms). We don't wait — fire
        // the timer's triggered() directly to exercise the inner handler,
        // which calls player.pause() (Mpv.qml:107-109). Assert via the
        // stub's pauseCount recorder.
        function findTimer(parent) {
            const buckets = [parent.children || [], parent.data || []];
            for (const b of buckets) {
                for (let i = 0; i < b.length; i++) {
                    const t = b[i];
                    if (t && typeof t.start === "function" &&
                        typeof t.interval !== "undefined" &&
                        t.interval >= 200 && t.interval < 250) return t;
                }
            }
            return null;
        }
        const timer = findTimer(mpv);
        verify(timer !== null);
        const p = _findMpvPlayer();
        const n = p.pauseCount;
        timer.triggered();
        compare(p.pauseCount, n + 1);
    }

    // sourceLoadFailed routes to loadInfoShow AND stops the 15s watchdog
    // so the user sees a real diagnostic immediately. Mirrors
    // test_loadWatchdog_triggerRunsBody: emit the signal on the player
    // stub, observe loadInfoShowCount + lastLoadInfoMsg, and confirm the
    // watchdog Timer is no longer running.
    function test_sourceLoadFailed_routesReasonToInfoShow() {
        const p = _findMpvPlayer();
        verify(p !== null);
        // Locate the 15s watchdog (same helper-shape used by the
        // existing watchdog-trigger test).
        function findWatchdog(parent) {
            const buckets = [parent.children || [], parent.data || []];
            for (const b of buckets) {
                for (let i = 0; i < b.length; i++) {
                    const t = b[i];
                    if (t && typeof t.start === "function" &&
                        typeof t.interval !== "undefined" &&
                        t.interval === 15000) return t;
                }
            }
            return null;
        }
        const wd = findWatchdog(mpv);
        verify(wd !== null);
        // Force a known starting state — other tests in this TestCase may
        // have already triggered the watchdog (or qmltestrunner ordering
        // may differ). What this test actually exercises is the contract
        // "emitting sourceLoadFailed calls loadWatchdog.stop()."
        wd.restart();
        verify(wd.running);

        const n = loadInfoShowCount;
        // Emit on the stub player as the real C++ signal would.
        p.sourceLoadFailed("decode failed: no demuxer for this format");
        compare(loadInfoShowCount, n + 1);
        verify(lastLoadInfoMsg.indexOf("decode failed") !== -1);
        // The Connections handler must stop the watchdog so the 15s
        // generic message can't fire on top of the real one.
        verify(! wd.running);
    }

    // Regression: a sourceLoadFailed with an empty reason still routes;
    // the QML message format does not require a non-empty reason (the
    // C++ contract does — see the unit test — but the QML layer must
    // not crash on a malformed signal in case a future refactor
    // forwards an unbound QString).
    function test_sourceLoadFailed_handlesEmptyReasonGracefully() {
        const p = _findMpvPlayer();
        const n = loadInfoShowCount;
        p.sourceLoadFailed("");
        compare(loadInfoShowCount, n + 1);
        // The message text is whatever the Connections handler composed —
        // we only assert that the routing happened.
    }
}
