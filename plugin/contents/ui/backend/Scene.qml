import QtQuick 2.5
import com.github.captsilver.wallpaperEngineKde 1.2
import ".."
import "../js/layout.mjs" as Layout

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

    // displayMode no longer drives fillMode imperatively: the player binds its
    // size + fillMode to the pure Layout helpers below, so both follow
    // displayMode and nativeAspectRatio reactively (the old onDisplayModeChanged
    // handler + a 50ms displayModeFixTimer that fought a separate item-letterbox
    // are gone).

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
        // Keep-Aspect-Ratio: size the renderer to the wallpaper's native aspect
        // and centre it, so the letterbox region is the parent `background`
        // Rectangle (BackgroundColor) showing through.  fillMode is STRETCH once
        // the native aspect is known (the item is already native-aspect, so the
        // renderer fills it exactly with NO opaque padding); the previous code
        // left it ASPECTFIT, which painted black bars whenever the item stayed
        // full-size.  Size + fillMode are bindings over the pure Layout helpers
        // (plugin/contents/ui/js/layout.mjs) so they are unit-testable and follow
        // displayMode/nativeAspectRatio reactively.
        anchors.centerIn: parent
        readonly property bool isAspect: sceneItem.displayMode === Common.DisplayMode.Aspect
        readonly property bool isCrop:   sceneItem.displayMode === Common.DisplayMode.Crop
        readonly property var  _box: Layout.letterboxSize(isAspect, nativeAspectRatio,
                                                          parent.width, parent.height)
        width:  _box.width
        height: _box.height
        fillMode: Layout.fillModeFor(isAspect, isCrop, nativeAspectRatio,
                                     { STRETCH: SceneViewer.STRETCH,
                                       ASPECTFIT: SceneViewer.ASPECTFIT,
                                       ASPECTCROP: SceneViewer.ASPECTCROP })

        // Diagnostic (kept per debug-logging policy): one-shot per load, lets a
        // real multi-monitor install confirm in journalctl that nativeAspectRatio
        // reaches QML (>0) on the ultrawide.  Grep: "WEK] letterbox".
        onNativeAspectRatioChanged: if (nativeAspectRatio > 0)
            console.log("[WEK] letterbox: nativeAspect=" + nativeAspectRatio
                + " parent=" + parent.width + "x" + parent.height
                + " item=" + width + "x" + height + " fillMode=" + fillMode);

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
