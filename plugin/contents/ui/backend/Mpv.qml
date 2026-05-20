import QtQuick 2.5
import com.github.captsilver.wallpaperEngineKde 1.2
import ".."

Item{
    id: videoItem
    anchors.fill: parent
    property alias source: player.source
    readonly property int displayMode: background.displayMode
    readonly property real videoRate: background.speed
    readonly property bool stats: background.mpvStats
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
                background.sig_backendFirstFrame('mpv');
                loadWatchdog.stop();
            }
        }
    }

    // MpvBackend doesn't emit an explicit error signal — if libmpv can't
    // load the source (missing file, codec failure, etc.) firstFrame
    // never fires. A 15s watchdog catches this and falls back to InfoShow
    // so the user sees a real message instead of a permanent black screen.
    Timer {
        id: loadWatchdog
        interval: 15000
        repeat: false
        running: true
        onTriggered: {
            if (videoItem.parent
                && typeof videoItem.parent.loadInfoShow === "function") {
                videoItem.parent.loadInfoShow(
                    "MPV failed to produce a frame within 15s — file may be unsupported or missing.");
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
