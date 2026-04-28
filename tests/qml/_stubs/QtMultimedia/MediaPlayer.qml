import QtQuick
QtObject {
    enum Loops { Infinite }
    property url    source:        ""
    property real   playbackRate:  1.0
    property var    videoOutput:   null
    property var    audioOutput:   null
    property int    loops:         0

    function play()  {}
    function pause() {}
    function stop()  {}
}
