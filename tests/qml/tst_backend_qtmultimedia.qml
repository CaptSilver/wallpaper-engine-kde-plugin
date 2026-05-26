import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    name: "Backend_QtMultimedia"
    width: 200; height: 100
    when: windowShown

    BackgroundFake { id: background }

    // loadInfoShow recorder — the Connections.onErrorOccurred handler in
    // QtMultimedia.qml calls `videoItem.parent.loadInfoShow(msg)` when
    // the parent exposes it. videoItem's parent is this TestCase, so we
    // capture the routed call here.
    property int    loadInfoShowCount: 0
    property string lastLoadInfoMsg:   ""
    function loadInfoShow(msg) {
        loadInfoShowCount += 1;
        lastLoadInfoMsg    = msg;
    }

    Backend.QtMultimedia {
        id: qm
        source: "stub://video.mp4"
    }

    function test_backendNameSetByCompleted() {
        compare(background.nowBackend, "QtMultimedia");
    }

    function test_play_pause_togglesPauseTimer() {
        // play()  → pauseTimer.stop()  (QtMultimedia.qml:78-80)
        // pause() → pauseTimer.start() (QtMultimedia.qml:82-85)
        // The MediaPlayer stub has no play/pause recorder, so we observe
        // the pauseTimer.running flag instead — it's flipped by both
        // methods. (Stub gap: MediaPlayer.play/pause/stop bodies in
        // tests/qml/_stubs/QtMultimedia/MediaPlayer.qml have no recorders;
        // adding playCount/pauseCount there would let us also assert the
        // direct player.play() side of play().)
        const timer = _findPauseTimer();
        verify(timer !== null);
        qm.pause();
        compare(timer.running, true);
        qm.play();
        compare(timer.running, false);
    }

    function test_displayModeBranches() {
        // onDisplayModeChanged sets videoView.fillMode per branch
        // (QtMultimedia.qml:16-22). videoView is a VideoOutput child;
        // its fillMode property is observable on the stub. displayMode
        // is bound to background.displayMode (QtMultimedia.qml:9), so
        // reassignment auto-fires the handler.
        const view = _findVideoView();
        verify(view !== null);
        const cases = [
            { mode: Plugin.Common.DisplayMode.Aspect, fill: 1 /* PreserveAspectFit */ },
            { mode: Plugin.Common.DisplayMode.Crop,   fill: 2 /* PreserveAspectCrop */ },
            { mode: Plugin.Common.DisplayMode.Scale,  fill: 0 /* Stretch */ },
        ];
        for (const c of cases) {
            background.displayMode = c.mode;
            compare(view.fillMode, c.fill);
        }
    }

    function test_getMouseTargetReturnsUndefined() {
        compare(qm.getMouseTarget(), undefined);
    }

    // Connections.onErrorOccurred@63 — routes player error to InfoShow.
    // Find the MediaPlayer + fire errorOccurred(error, errorString) on it;
    // the Connections handler in QtMultimedia.qml runs through and the
    // TestCase's loadInfoShow recorder captures the routed call.
    function test_playerErrorOccurred_routesToInfoShow() {
        const player = _findPlayer();
        if (!player) return; // offscreen QPA may not realise MediaPlayer
        const n = loadInfoShowCount;
        // MediaPlayer.errorOccurred(MediaPlayer.Error, string). Calling
        // the signal directly from JS coerces ints into the enum.
        player.errorOccurred(1, "stub failure");
        compare(loadInfoShowCount, n + 1);
        verify(lastLoadInfoMsg.indexOf("stub failure") !== -1);
    }

    function test_pauseTimer_triggeredFiresWithoutThrow_constructs() {
        // Genuine "constructs" case — pauseTimer onTriggered calls
        // player.pause() (QtMultimedia.qml:91-93), and the MediaPlayer
        // stub has no pauseCount recorder so we cannot observe the
        // forwarded call directly. Structurally assert that the timer
        // exists with the documented interval (300ms) and that firing
        // it executes without throwing. (Stub gap: adding
        // pauseCount/playCount to tests/qml/_stubs/QtMultimedia/MediaPlayer.qml
        // would let this assert player.pause() routed.)
        const timer = _findPauseTimer();
        verify(timer !== null);
        compare(timer.interval, 300);
        timer.triggered();
    }

    function _findPlayer() {
        const buckets = [qm.children || [], qm.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const p = b[i];
                if (p && typeof p.play === "function"
                    && typeof p.errorOccurred === "function") return p;
            }
        }
        return null;
    }

    function _findVideoView() {
        const buckets = [qm.children || [], qm.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && typeof b[i].fillMode !== "undefined") return b[i];
            }
        }
        return null;
    }

    function _findPauseTimer() {
        const buckets = [qm.children || [], qm.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const t = b[i];
                if (t && typeof t.start === "function" &&
                    typeof t.interval !== "undefined" &&
                    t.interval >= 250 && t.interval <= 350) return t;
            }
        }
        return null;
    }
}
