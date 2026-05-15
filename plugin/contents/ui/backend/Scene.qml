import QtQuick 2.5
import com.github.captsilver.wallpaperEngineKde 1.2
import ".."

Item{
    id: sceneItem
    anchors.fill: parent
    property alias source: player.source
    property string assets: "assets"
    property int displayMode: background.displayMode
    property string userPropsJson: background.userPropsJson
    property var volumeFade: Common.createVolumeFade(
        sceneItem, 
        Qt.binding(function() { return background.mute ? 0 : background.volume; }),
        (volume) => { player.volume = volume / 100.0; }
    )

    onDisplayModeChanged: {
        if(displayMode == Common.DisplayMode.Scale)
            player.fillMode = SceneViewer.STRETCH;
        else if(displayMode == Common.DisplayMode.Aspect)
            player.fillMode = SceneViewer.ASPECTFIT;
        else if(displayMode == Common.DisplayMode.Crop)
            player.fillMode = SceneViewer.ASPECTCROP;
    }

    // Force fillMode update on background.displayMode change
    Timer {
        id: displayModeFixTimer
        interval: 50
        repeat: false
        onTriggered: sceneItem.displayModeChanged()
    }
    Connections {
        target: background
        function onDisplayModeChanged() {
            displayModeFixTimer.restart();
        }
    }

    MprisMonitor {
        id: mprisMonitor
        onPlaybackStateChanged: function(state) {
            player.mediaPlaybackChanged(state);
        }
        onPropertiesChanged: function(title, artist, albumTitle, albumArtist, genres, duration) {
            player.mediaPropertiesChanged(title, artist, albumTitle, albumArtist, genres, duration);
        }
        onThumbnailChanged: function(hasThumbnail, colors) {
            player.mediaThumbnailChanged(hasThumbnail, colors);
        }
        onTimelineChanged: function(position, duration, state) {
            player.mediaTimelineChanged(position, duration, state);
        }
        onEnabledChanged: function(enabled) {
            player.mediaStatusChanged(enabled);
        }
    }

    SceneViewer {
        id: player
        anchors.fill: parent
        fps: background.fps
        muted: background.mute
        speed: background.speed
        assets: sceneItem.assets
        userProperties: sceneItem.userPropsJson
        hdrOutput: background.hdrOutput
        postprocessingOverride: background.postProcessing
        systemAudioCapture: background.systemAudioCapture
        Component.onCompleted: {
            player.setAcceptMouse(true);
            player.setAcceptHover(true);
        }

        Connections {
            target: player
            function onFirstFrame() {
                background.sig_backendFirstFrame('scene');
            }
            // Route SceneScript engine.openUserShortcut(name) to MPRIS for
            // well-known media-control names (bplay/bnext/bprev and the
            // numeric aliases solar system uses). Unmapped names still fire
            // the `userShortcut` scene-bus event so wallpapers can handle
            // their own custom shortcuts in-script.
            function onUserShortcutRequested(name) {
                mprisMonitor.invokeShortcut(name);
            }
        }
    }

    Component.onCompleted: {
        background.nowBackend = 'scene';
        sceneItem.displayModeChanged();
    }
    function play() {
        volumeFade.start();
        player.play();
    }
    function pause() {
        volumeFade.stop();
        player.pause();
    }
    
    function getMouseTarget() {
        return Qt.binding(function() { return player; })
    }
}
