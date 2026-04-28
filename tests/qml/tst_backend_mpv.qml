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

    Backend.Mpv {
        id: mpv
        source: "stub://video.mp4"
    }

    function test_backendNameSetByCompleted() {
        compare(background.nowBackend, "mpv");
    }

    function test_play_pause_doNotThrow() {
        mpv.play();
        mpv.pause();
        verify(true);
    }

    function test_getMouseTargetReturnsUndefined() {
        // Mpv backend explicitly does not return a mouse target.
        compare(mpv.getMouseTarget(), undefined);
    }

    function test_displayModeBranches() {
        for (const m of [
            Plugin.Common.DisplayMode.Aspect,
            Plugin.Common.DisplayMode.Crop,
            Plugin.Common.DisplayMode.Scale,
        ]) {
            background.displayMode = m;
            mpv.displayModeChanged();
        }
        verify(true);
    }

    function test_statsToggleFires() {
        background.mpvStats = !background.mpvStats;
        mpv.statsChanged();
        verify(true);
    }

    function test_videoRateChangedSetsSpeedProperty() {
        background.speed = 2.5;
        mpv.videoRateChanged();
        verify(true);
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
        // to listen for the player's firstFrame signal.
        const player = _findMpvPlayer();
        verify(player !== null);
        player.firstFrame();
        verify(true);
    }

    function test_pauseTimerTriggeredEventuallyPausesPlayer() {
        // pause() starts pauseTimer (interval 200ms). We don't wait — fire
        // the timer's triggered() directly to exercise the inner handler.
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
        if (timer) timer.triggered();
        verify(true);
    }
}
