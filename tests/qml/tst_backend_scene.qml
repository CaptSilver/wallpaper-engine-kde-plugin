import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    id: tc
    name: "Backend_Scene"
    width: 200; height: 100
    when: windowShown

    // Sibling `background` provides the wek context surface. Children look up
    // unqualified `background` via parent QML scope.
    BackgroundFake { id: background }

    // loadInfoShow recorder — Scene.qml routes a load failure through
    // `sceneItem.parent.loadInfoShow(msg)`, and the TestCase is the parent.
    property int    loadInfoShowCount: 0
    property string lastLoadInfoMsg: ""
    function loadInfoShow(msg) {
        loadInfoShowCount += 1;
        lastLoadInfoMsg = String(msg);
    }

    Backend.Scene {
        id: scene
        source: "stub://scene.pkg"
    }

    // SignalSpies on the player surface. `target` is set per-test in the
    // body (after _findScenePlayer locates the child); declaring them as
    // children of the TestCase keeps lifetimes clean across cases.
    SignalSpy { id: playbackSpy;  signalName: "mediaPlaybackChanged"  }
    SignalSpy { id: propsSpy;     signalName: "mediaPropertiesChanged" }
    SignalSpy { id: thumbSpy;     signalName: "mediaThumbnailChanged" }
    SignalSpy { id: timelineSpy;  signalName: "mediaTimelineChanged"  }
    SignalSpy { id: statusSpy;    signalName: "mediaStatusChanged"    }
    SignalSpy { id: ffSpy;        target: background; signalName: "sig_backendFirstFrame" }

    function test_alphabeticBackendIsSetByOnCompleted() {
        compare(background.nowBackend, "scene");
    }

    function test_play_callsPlayerPlay() {
        const p = _findScenePlayer();
        const n = p.playCount;
        scene.play();
        compare(p.playCount, n + 1);
    }

    function test_pause_callsPlayerPause() {
        const p = _findScenePlayer();
        const n = p.pauseCount;
        scene.pause();
        compare(p.pauseCount, n + 1);
    }

    function test_getMouseTarget_returnsBinding() {
        const t = scene.getMouseTarget();
        verify(t !== undefined);
    }

    function test_displayModeAspect_loaded_setsStretch() {
        const p = _findScenePlayer();
        background.displayMode = Plugin.Common.DisplayMode.Aspect;
        p.nativeAspectRatio = 16 / 9;
        compare(p.fillMode, 0 /* STRETCH */);
    }
    function test_displayModeAspect_notLoaded_setsAspectFit() {
        const p = _findScenePlayer();
        background.displayMode = Plugin.Common.DisplayMode.Aspect;
        p.nativeAspectRatio = 0;
        compare(p.fillMode, 1 /* ASPECTFIT */);
    }
    function test_displayModeCrop_setsAspectCrop() {
        const p = _findScenePlayer();
        background.displayMode = Plugin.Common.DisplayMode.Crop;
        compare(p.fillMode, 2 /* ASPECTCROP */);
    }

    // ── MprisMonitor signal handlers ──────────────────────────────────────────
    function _findChildByMethodName(parent, method) {
        const buckets = [parent.children || [], parent.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && typeof b[i][method] === "function") return b[i];
            }
        }
        return null;
    }

    function test_mprisPlaybackStateForwardsToPlayer() {
        const mpris  = _findChildByMethodName(scene, "invokeShortcut");
        const player = _findScenePlayer();
        verify(mpris !== null);
        playbackSpy.target = player;
        playbackSpy.clear();
        mpris.playbackStateChanged("Playing");
        compare(playbackSpy.count, 1);
        compare(playbackSpy.signalArguments[0][0], "Playing");
    }

    function test_mprisPropertiesForwardsToPlayer() {
        const mpris  = _findChildByMethodName(scene, "invokeShortcut");
        const player = _findScenePlayer();
        propsSpy.target = player;
        propsSpy.clear();
        mpris.propertiesChanged("title", "artist", "albumTitle", "albumArtist", "", 60.0);
        compare(propsSpy.count, 1);
        compare(propsSpy.signalArguments[0][0], "title");
        compare(propsSpy.signalArguments[0][1], "artist");
        compare(propsSpy.signalArguments[0][2], "albumTitle");
        compare(propsSpy.signalArguments[0][3], "albumArtist");
        compare(propsSpy.signalArguments[0][5], 60.0);  // duration
    }

    function test_mprisThumbnailForwardsToPlayer() {
        const mpris  = _findChildByMethodName(scene, "invokeShortcut");
        const player = _findScenePlayer();
        thumbSpy.target = player;
        thumbSpy.clear();
        mpris.thumbnailChanged(true, [Qt.rgba(1,0,0,1)]);
        compare(thumbSpy.count, 1);
        compare(thumbSpy.signalArguments[0][0], true);
    }

    function test_mprisTimelineForwardsToPlayer() {
        const mpris  = _findChildByMethodName(scene, "invokeShortcut");
        const player = _findScenePlayer();
        timelineSpy.target = player;
        timelineSpy.clear();
        mpris.timelineChanged(0, 60, 1);
        compare(timelineSpy.count, 1);
        compare(timelineSpy.signalArguments[0][0], 0);
        compare(timelineSpy.signalArguments[0][1], 60);
        compare(timelineSpy.signalArguments[0][2], 1);  // state
    }

    function test_mprisEnabledForwardsToPlayer() {
        const mpris  = _findChildByMethodName(scene, "invokeShortcut");
        const player = _findScenePlayer();
        statusSpy.target = player;
        statusSpy.clear();
        const want = !mpris.enabled;
        mpris.enabled = want;
        compare(statusSpy.count, 1);
        compare(statusSpy.signalArguments[0][0], want);
    }

    // ── SceneViewer Connections handlers ──────────────────────────────────────
    function _findScenePlayer() {
        const buckets = [scene.children || [], scene.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && typeof b[i].setAcceptMouse === "function") return b[i];
            }
        }
        return null;
    }

    function test_scenePlayerFirstFrame_routesToBackgroundSignal() {
        const player = _findScenePlayer();
        verify(player !== null);
        ffSpy.clear();
        const n = background.firstFrameCount;
        player.firstFrame();
        compare(ffSpy.count, 1);
        compare(ffSpy.signalArguments[0][0], "scene");
        compare(background.firstFrameCount, n + 1);
        compare(background.lastFirstFrameName, "scene");
    }

    function test_scenePlayerUserShortcut_routesToMpris() {
        const player = _findScenePlayer();
        const mpris  = _findChildByMethodName(scene, "invokeShortcut");
        const n = mpris.invokeShortcutCount;
        player.userShortcutRequested("bplay");
        compare(mpris.invokeShortcutCount, n + 1);
        compare(mpris.lastShortcut, "bplay");
    }

    function test_displayModeScale_setsStretch() {
        const p = _findScenePlayer();
        background.displayMode = Plugin.Common.DisplayMode.Scale;
        compare(p.fillMode, 0 /* STRETCH */);
    }

    // videoDecodeFailed surfaces a transient overlay (NOT InfoShow, because
    // the wallpaper continues rendering without the broken texture).  The
    // overlay shows the summary string + visibility flips on emit.
    function _findVideoOverlay(parent) {
        const buckets = [parent.children || [], parent.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const o = b[i];
                if (o && typeof o.show === "function" &&
                    typeof o.lastSummary !== "undefined") return o;
            }
        }
        return null;
    }

    function test_videoDecodeFailed_showsTransientOverlay() {
        const player = _findScenePlayer();
        verify(player !== null);
        const overlay = _findVideoOverlay(scene);
        verify(overlay !== null);
        // Baseline: hidden via the `shown` flag (Item.visible reports
        // effective visibility, which under qmltestrunner may already be
        // false from ancestor chain; the `shown` flag is the authoritative
        // local toggle).
        verify(!overlay.shown);

        const summary = "Video texture missing.mp4: HW=err; SW=err";
        player.videoDecodeFailed(summary);
        // The Connections handler calls overlay.show(summary), which sets
        // shown=true + lastSummary=summary.  tryCompare polls because the
        // signal handler may not run synchronously under qmltestrunner.
        tryCompare(overlay, "lastSummary", summary);
        tryCompare(overlay, "shown", true);
    }

    // A scene that never produces a frame leaves the desktop showing only the
    // background colour, which is indistinguishable from a broken plugin. The
    // watchdog is the backstop that turns that into the InfoShow recovery
    // pane; fire triggered() directly rather than waiting out the interval.
    function _findLoadWatchdog() {
        const buckets = [scene.children || [], scene.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const t = b[i];
                if (t && typeof t.start === "function" &&
                    typeof t.interval !== "undefined" &&
                    t.interval === 20000) return t;
            }
        }
        return null;
    }

    function test_loadWatchdog_expiry_routesToInfoShow() {
        const wd = _findLoadWatchdog();
        verify(wd !== null);
        const n = loadInfoShowCount;
        wd.triggered();
        compare(loadInfoShowCount, n + 1);
        verify(lastLoadInfoMsg.indexOf("no frame") !== -1);
    }

    function test_firstFrame_stopsLoadWatchdog() {
        const wd = _findLoadWatchdog();
        verify(wd !== null);
        wd.restart();
        verify(wd.running);
        _findScenePlayer().firstFrame();
        verify(! wd.running);
    }

    function test_sourceChange_rearmsLoadWatchdog() {
        const wd = _findLoadWatchdog();
        wd.stop();
        verify(! wd.running);
        scene.source = "stub://another.pkg";
        verify(wd.running);
    }

    // main.qml pauses the backend 300ms into every launch and only plays it
    // back 5s later — and leaves it paused for as long as the desktop stays
    // occluded or locked. A paused scene has no frame for a legitimate reason,
    // so the watchdog must hold the watch open rather than cry wolf.
    function test_loadWatchdog_whilePaused_keepsWaiting() {
        const wd = _findLoadWatchdog();
        scene.pause();
        const n = loadInfoShowCount;
        wd.triggered();
        compare(loadInfoShowCount, n);
        verify(wd.running);
        scene.play();
    }

    function test_play_beforeFirstFrame_rearmsWatchdog() {
        scene.source = "stub://rearm.pkg";   // clears the first-frame latch
        const wd = _findLoadWatchdog();
        wd.stop();
        scene.play();
        verify(wd.running);
    }

    function test_play_afterFirstFrame_leavesWatchdogStopped() {
        const wd = _findLoadWatchdog();
        _findScenePlayer().firstFrame();
        verify(! wd.running);
        scene.play();
        verify(! wd.running);
    }

    // The GL-interop gate fails before the renderer ever starts, so the
    // watchdog's generic message is the wrong thing to show — the named
    // reason must reach InfoShow straight away and disarm the watchdog.
    function test_sceneLoadFailed_routesReasonAndStopsWatchdog() {
        const player = _findScenePlayer();
        const wd = _findLoadWatchdog();
        wd.restart();
        verify(wd.running);
        const n = loadInfoShowCount;
        player.sceneLoadFailed("GL interop init failed");
        compare(loadInfoShowCount, n + 1);
        verify(lastLoadInfoMsg.indexOf("GL interop init failed") !== -1);
        verify(! wd.running);
    }
}
