import QtQuick 2.5
import QtMultimedia
import ".."

Item{
    id: videoItem
    anchors.fill: parent
    property alias source: player.source
    property int displayMode: background.displayMode
    // Latch for the first-frame announcement below; a new clip gets a new
    // announcement, a pause/resume cycle does not.
    property bool announcedFirstFrame: false
    onSourceChanged: announcedFirstFrame = false
    property var volumeFade: Common.createVolumeFade(
        videoItem, 
        Qt.binding(function() { return background.mute ? 0 : background.volume; }),
        (volume) => { audioOut.volume = volume / 100.0; }
    )

    onDisplayModeChanged: {
        if(displayMode == Common.DisplayMode.Scale)
            videoView.fillMode = VideoOutput.Stretch;
        else if(displayMode == Common.DisplayMode.Aspect)
            videoView.fillMode = VideoOutput.PreserveAspectFit;
        else if(displayMode == Common.DisplayMode.Crop)
            videoView.fillMode = VideoOutput.PreserveAspectCrop;
    }

    // Force fillMode update on background.displayMode change
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

    VideoOutput {
        id: videoView
        //fillMode: wallpaper.configuration.FillMode
        anchors.fill: parent
    }
    AudioOutput {
        id: audioOut
        volume: 0.0
        muted: background.mute
    }
    MediaPlayer {
        id: player
        loops: MediaPlayer.Infinite
        playbackRate: background.speed
        videoOutput: videoView
        audioOutput: audioOut
    }
    // Surface load errors to InfoShow so users see a real reason instead
    // of a black screen. Use a Connections block — assigning
    // onErrorOccurred directly on MediaPlayer fails on Qt 6 because the
    // signal isn't exposed as a settable property at the QML type level.
    Connections {
        target: player
        ignoreUnknownSignals: true
        function onErrorOccurred(error, errorString) {
            console.warn("[WEK QtMultimedia] error", error, errorString);
            if (videoItem.parent
                && typeof videoItem.parent.loadInfoShow === "function") {
                videoItem.parent.loadInfoShow(
                    "Video failed to load: " + (errorString || ("error " + error)));
            }
        }
        // The other three backends emit a real first-frame signal; main.qml
        // needs the announcement to stamp the version it just displayed
        // (that stamp is what clears the "Updated" badge). QtMultimedia has
        // nothing frame-level to hook, so playback entering PlayingState is
        // the closest honest equivalent — by then the decoder has handed the
        // VideoOutput something to show.
        function onPlaybackStateChanged() {
            if (player.playbackState !== MediaPlayer.PlayingState) return;
            if (videoItem.announcedFirstFrame) return;
            videoItem.announcedFirstFrame = true;
            background.sig_backendFirstFrame('QtMultimedia');
        }
    }
    Component.onCompleted:{
        background.nowBackend = "QtMultimedia";
        videoItem.displayModeChanged();
    }

    function play(){
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
        interval: 300
        onTriggered: {
            player.pause();
        }
    }
    function getMouseTarget() {
    }
}
