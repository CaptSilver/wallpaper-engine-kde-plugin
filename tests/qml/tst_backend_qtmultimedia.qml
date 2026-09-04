import QtQuick
import QtTest
import QtMultimedia

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    id: tc
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

    // Cases that need a backend with untouched playback state build their own
    // instance — `qm` is shared and the first-frame announcement latches.
    Component { id: qmComp; Backend.QtMultimedia { source: "stub://fresh.mp4" } }

    function test_backendNameSetByCompleted() {
        compare(background.nowBackend, "QtMultimedia");
    }

    // pause() only arms the 300ms fade-out timer; play() disarms it and starts
    // the player straight away.
    function test_play_pause_togglesPauseTimerAndPlayerState() {
        const timer = _findPauseTimer();
        const player = _findPlayer();
        verify(timer !== null);
        verify(player !== null);
        qm.pause();
        compare(timer.running, true);
        qm.play();
        compare(timer.running, false);
        compare(player.playbackState, MediaPlayer.PlayingState);
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
        verify(player !== null);
        const n = loadInfoShowCount;
        // MediaPlayer.errorOccurred(MediaPlayer.Error, string). Calling
        // the signal directly from JS coerces ints into the enum.
        player.errorOccurred(1, "stub failure");
        compare(loadInfoShowCount, n + 1);
        verify(lastLoadInfoMsg.indexOf("stub failure") !== -1);
    }

    // The 300ms delay lets the volume fade finish before the picture stops;
    // when it expires the player really has to pause.
    function test_pauseTimerExpiry_pausesThePlayer() {
        const timer = _findPauseTimer();
        const player = _findPlayer();
        verify(timer !== null);
        verify(player !== null);
        compare(timer.interval, 300);
        player.play();
        timer.triggered();
        compare(player.playbackState, MediaPlayer.PausedState);
    }

    // Every backend announces its first frame to main.qml; that emit is what
    // stamps the loaded version and clears the "Updated" badge in the picker.
    // QtMultimedia has no frame-level signal, so playback reaching PlayingState
    // is the hook.
    function test_playbackStarting_announcesFirstFrame() {
        const item = qmComp.createObject(tc);
        verify(item !== null);
        const player = _findPlayer(item);
        verify(player !== null);

        background.firstFrameCount = 0;
        background.lastFirstFrameName = undefined;
        player.play();

        compare(background.firstFrameCount, 1);
        compare(background.lastFirstFrameName, "QtMultimedia");
        item.destroy();
    }

    // Resuming after a pause is not a new first frame — re-announcing would
    // re-stamp the version on every pause cycle for no reason.
    function test_resumeAfterPause_doesNotReAnnounceFirstFrame() {
        const item = qmComp.createObject(tc);
        verify(item !== null);
        const player = _findPlayer(item);
        verify(player !== null);

        background.firstFrameCount = 0;
        player.play();
        player.pause();
        player.play();

        compare(background.firstFrameCount, 1);
        item.destroy();
    }

    function _findPlayer(root) {
        root = root || qm;
        const buckets = [root.children || [], root.data || []];
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
