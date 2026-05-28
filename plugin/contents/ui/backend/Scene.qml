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
        // Read MprisMonitor.enabled directly: the C++ signal carries the
        // bool arg, but in QML the auto-generated property change signal is
        // parameterless. A function(enabled) wrapper would receive undefined
        // under a QML stub (bool-coerced to false) and silently mis-route.
        onEnabledChanged: {
            player.mediaStatusChanged(mprisMonitor.enabled);
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
        // Swapchain present-mode policy + monitor refresh rate.  Forwarded
        // raw to SceneViewer's Q_PROPERTYs which marshal them into
        // SceneWallpaper via the PROPERTY_PRESENT_MODE / PROPERTY_OUTPUT_REFRESH_HZ
        // routes.  Background defaults (Auto + 60Hz) preserve today's behaviour
        // when the user hasn't touched the new ComboBox.
        presentMode: background.presentMode
        outputRefreshHz: background.outputRefreshHz
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
            // Transient overlay for video-decode failures. Deliberately NOT
            // routed through loadInfoShow: the rest of the scene keeps
            // rendering while one bad video texture surfaces a short toast.
            // A video wallpaper has only the video, so the Mpv backend uses
            // loadInfoShow there; here a scene has other content to preserve.
            function onVideoDecodeFailed(summary) {
                videoDecodeOverlay.show(summary);
            }
        }
    }

    // Transient overlay for video-decode failures. 5s fade after show().
    // Lives outside the SceneViewer so anchors target the wrapper Item and
    // the overlay stays visible even if the player resizes mid-display.
    // `shown` drives visibility (Item.visible defaults true so a direct
    // `visible: false` binding can win over later JS assignment in some
    // qmltestrunner conditions; bind visible to the explicit flag instead).
    Item {
        id: videoDecodeOverlay
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 24
        // Fixed-but-bounded width so the height binding can resolve without
        // looping (Text.implicitHeight is read by the height binding, so the
        // Text must be sized by width not anchors.fill).
        width: Math.min(parent.width * 0.5, 600)
        height: overlayLabel.implicitHeight + 24
        visible: shown
        opacity: shown ? 1.0 : 0
        // Public surface read by tst_backend_scene; production reads the
        // Text below which binds to lastSummary.  `shown` drives `visible`
        // via a binding so JS-side `show()` mutates only this flag.
        property bool   shown: false
        property string lastSummary: ""

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.7)
            radius: 6
        }
        Text {
            id: overlayLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 12
            color: "white"
            wrapMode: Text.WordWrap
            text: videoDecodeOverlay.lastSummary
        }
        Behavior on opacity { NumberAnimation { duration: 250 } }
        Timer {
            id: overlayFadeTimer
            interval: 5000
            repeat: false
            onTriggered: videoDecodeOverlay.shown = false
        }
        function show(summary) {
            lastSummary = summary;
            shown = true;
            overlayFadeTimer.restart();
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
