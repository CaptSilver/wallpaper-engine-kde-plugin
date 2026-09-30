import QtQuick 2.5
import com.github.captsilver.wallpaperEngineKde 1.2
import ".."

Item{
    id: videoItem
    // Set once this backend has put a frame on screen; main.qml keeps the
    // previous backend visible until then.
    property bool frameShown: false
    anchors.fill: parent
    property alias source: player.source
    property int displayMode: background.displayMode
    property real videoRate: background.speed
    readonly property bool stats: background.mpvStats
    // No userPropsJson binding on purpose. A project.json property binds to a
    // shader uniform or a scene script, and a video has neither — mpv just
    // plays the file. The wallpaper settings hide those controls for video
    // wallpapers to match; wiring one here means going back and re-enabling
    // them.
    property var volumeFade: Common.createVolumeFade(
        videoItem, 
        Qt.binding(function() { return background.mute ? 0 : background.volume; }),
        (volume) => { player.volume = volume; }
    )
    
    onDisplayModeChanged: {
        if(videoItem.displayMode == Common.DisplayMode.Crop) {
            player.setProperty("keepaspect", true);
            player.setProperty("panscan", 1.0);
        } else if(videoItem.displayMode == Common.DisplayMode.Aspect) {
            player.setProperty("keepaspect", true);
            player.setProperty("panscan", 0.0);
        } else if(videoItem.displayMode == Common.DisplayMode.Scale) {
            player.setProperty("keepaspect", false);
            player.setProperty("panscan", 0.0);
        }
    }

    // Force displayMode update on background.displayMode change
    Timer {
        id: displayModeFixTimer
        interval: 50
        repeat: false
        onTriggered: videoItem.displayModeChanged()
    }
    Connections {
        target: background
        function onDisplayModeChanged() {
            displayModeFixTimer.restart();
        }
    }
    // it's ok for toggle, true will always cause a signal at first
    onStatsChanged: {
        player.command(["script-binding","stats/display-stats-toggle"]);
    }

    onVideoRateChanged: player.setProperty('speed', videoRate);

    // logfile
    // source
    // mute
    // volume
    // fun:setProperty(name,value)
    Mpv {
        id: player
        anchors.fill: parent
        mute: background.mute
        volume: 0
        Connections {
            ignoreUnknownSignals: true
            function onFirstFrame() {
                videoItem.frameShown = true;
                background.sig_backendFirstFrame('mpv');
                loadWatchdog.stop();
            }
        }
    }

    // MpvBackend now emits sourceLoadFailed for both sync (loadfile reject)
    // and async (MPV_EVENT_END_FILE reason=ERROR) failures — handled by
    // the Connections block below, which routes the reason to InfoShow
    // immediately and stops the watchdog. The watchdog stays in place
    // as a true-silent-hang backstop: it only fires when mpv accepts
    // the load, never emits END_FILE, and never produces a frame — a
    // shape we still see for sources that mpv opens but stalls on.
    Connections {
        target: player
        ignoreUnknownSignals: true
        function onSourceLoadFailed(reason) {
            loadWatchdog.stop();
            if (videoItem.parent
                && typeof videoItem.parent.loadInfoShow === "function") {
                videoItem.parent.loadInfoShow(
                    "MPV could not load this video: " + reason);
            }
        }
    }
    Timer {
        id: loadWatchdog
        interval: 15000
        repeat: false
        running: true
        onTriggered: {
            if (videoItem.parent
                && typeof videoItem.parent.loadInfoShow === "function") {
                videoItem.parent.loadInfoShow(
                    "MPV produced no frame within 15s.");
            }
        }
    }
    Component.onCompleted:{
        background.nowBackend = 'mpv';
        videoItem.displayModeChanged();
    }

    function play(){
        // stop pause time to avoid quick switch which cause keep pause 
        pauseTimer.stop();
        player.play();
        volumeFade.start();
    }
    // main.qml calls this when the backend becomes the outgoing layer of a
    // handoff: background.* then describes the next wallpaper, so pin the
    // options this one is showing instead of following them.
    function freezeOptions() {
        displayMode = displayMode;
        videoRate = videoRate;
    }
    function pause(){
        volumeFade.stop();
        pauseTimer.start();
    }
    Timer{
        id: pauseTimer
        running: false
        repeat: false
        interval: 200
        onTriggered: {
            player.pause();
        }
    }
    function getMouseTarget() {
    }
}
