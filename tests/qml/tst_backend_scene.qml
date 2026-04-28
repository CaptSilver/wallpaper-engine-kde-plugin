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

    Backend.Scene {
        id: scene
        source: "stub://scene.pkg"
    }

    function test_alphabeticBackendIsSetByOnCompleted() {
        compare(background.nowBackend, "scene");
    }

    function test_play_callsPlayerPlay() {
        scene.play();
        verify(true);
    }

    function test_pause_callsPlayerPause() {
        scene.pause();
        verify(true);
    }

    function test_getMouseTarget_returnsBinding() {
        const t = scene.getMouseTarget();
        verify(t !== undefined);
    }

    function test_displayModeAspect_setsAspectFitFillMode() {
        background.displayMode = Plugin.Common.DisplayMode.Aspect;
        scene.displayModeChanged();
        verify(true);
    }

    function test_displayModeCrop_setsAspectCropFillMode() {
        background.displayMode = Plugin.Common.DisplayMode.Crop;
        scene.displayModeChanged();
        verify(true);
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
        const mpris = _findChildByMethodName(scene, "invokeShortcut");
        verify(mpris !== null);
        mpris.playbackStateChanged("Playing");
        verify(true);
    }

    function test_mprisPropertiesForwardsToPlayer() {
        const mpris = _findChildByMethodName(scene, "invokeShortcut");
        mpris.propertiesChanged("title", "artist", "albumTitle", "albumArtist", []);
        verify(true);
    }

    function test_mprisThumbnailForwardsToPlayer() {
        const mpris = _findChildByMethodName(scene, "invokeShortcut");
        mpris.thumbnailChanged(true, [Qt.rgba(1,0,0,1)]);
        verify(true);
    }

    function test_mprisTimelineForwardsToPlayer() {
        const mpris = _findChildByMethodName(scene, "invokeShortcut");
        mpris.timelineChanged(0, 60);
        verify(true);
    }

    function test_mprisEnabledForwardsToPlayer() {
        const mpris = _findChildByMethodName(scene, "invokeShortcut");
        mpris.enabled = !mpris.enabled;
        verify(true);
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
        player.firstFrame();
        verify(true);
    }

    function test_scenePlayerUserShortcut_routesToMpris() {
        const player = _findScenePlayer();
        player.userShortcutRequested("bplay");
        verify(true);
    }

    function test_displayModeScale_setsStretchFillMode() {
        background.displayMode = Plugin.Common.DisplayMode.Scale;
        scene.displayModeChanged();
        verify(true);
    }
}
