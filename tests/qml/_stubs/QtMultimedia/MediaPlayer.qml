// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: Qt 6 QtMultimedia docs (type-import placeholder)
// Last contract review: 2026-05-27

import QtQuick
QtObject {
    enum Loops { Infinite }
    property url    source:        ""
    property real   playbackRate:  1.0
    property var    videoOutput:   null
    property var    audioOutput:   null
    property int    loops:         0

    // QMediaPlayer::errorOccurred(Error, QString). The backend routes it to the
    // InfoShow overlay, so tests need to be able to fire it.
    signal errorOccurred(int error, string errorString)

    // Ordinals match QMediaPlayer::PlaybackState so production comparisons
    // against MediaPlayer.PlayingState read the same here as on real Qt.
    enum PlaybackState { StoppedState, PlayingState, PausedState }
    property int    playbackState: MediaPlayer.StoppedState

    function play()  { playbackState = MediaPlayer.PlayingState }
    function pause() { playbackState = MediaPlayer.PausedState  }
    function stop()  { playbackState = MediaPlayer.StoppedState }
}
