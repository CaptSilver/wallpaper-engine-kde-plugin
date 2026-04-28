// Stub for the C++ MpvObject (registered as `Mpv` from the wek-plugin module).
// libmpv decoder isn't going to live in qmltestrunner; we just provide the
// QML API surface that backend/Mpv.qml drives.
import QtQuick
Item {
    property string source:    ""
    property real   volume:    50
    property bool   mute:      false

    function play()                {}
    function pause()               {}
    function stop()                {}
    function command(cmd)          {}
    function setProperty(name, val) {}

    signal firstFrame()
}
