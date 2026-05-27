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

    function play()  {}
    function pause() {}
    function stop()  {}
}
