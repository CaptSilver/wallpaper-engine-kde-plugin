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

    // MPRIS media-control + metadata bridge. SceneScript JS in scene
    // wallpapers can subscribe to playback state, properties (title /
    // artist / album / genres / duration), timeline (position), and
    // thumbnail color extraction via mediaPlaybackChanged etc. on the
    // player object. SceneScript can also dispatch transport controls
    // via engine.openUserShortcut("bplaypause"/"bnext"/...).
    //
    // Web (QtWebView.qml) and Video (QtMultimedia.qml/Mpv.qml) backends
    // do NOT currently wire this up — there's no QWebChannel proxy for
    // MprisMonitor on the web side, and video wallpapers have no script
    // surface to dispatch media keys from. If you need media-control
    // dispatch from web, expose mprisMonitor.invokeShortcut to the page
    // via WebAudioBridge-style relay (the asymmetry is intentional
    // today, not a bug — but worth noting since users may expect parity).
    MprisMonitor {
        id: mprisMonitor
        // Engage the D-Bus watch + position poll so signals fire for
        // scene-script subscribers. Other backends skip the cost
        // automatically (they never instantiate MprisMonitor).
        Component.onCompleted: engage()
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
        // Keep-Aspect-Ratio (ASPECTFIT): size the renderer to the wallpaper's
        // native aspect and centre it, so the letterbox region is the parent
        // `background` Rectangle (BackgroundColor) showing through rather than
        // the renderer painting opaque bars.  Stretch/Crop — and the interval
        // before the scene loads (nativeAspectRatio == 0) — fill the whole area.
        anchors.centerIn: parent
        readonly property bool letterbox: sceneItem.displayMode === Common.DisplayMode.Aspect && nativeAspectRatio > 0
        width: {
            if (!letterbox) return parent.width;
            return nativeAspectRatio > parent.width / parent.height ? parent.width : parent.height * nativeAspectRatio;
        }
        height: {
            if (!letterbox) return parent.height;
            return nativeAspectRatio > parent.width / parent.height ? parent.width / nativeAspectRatio : parent.height;
        }
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
