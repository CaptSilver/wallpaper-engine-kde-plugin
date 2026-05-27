// Stub for the C++ MpvObject (registered as `Mpv` from the wek-plugin module).
// libmpv decoder isn't going to live in qmltestrunner; we just provide the
// QML API surface that backend/Mpv.qml drives.
import QtQuick
Item {
    property string source:    ""
    property real   volume:    50
    property bool   mute:      false

    // ── test recorders (test-only stub) ──────────────────────────────────
    property int  playCount:        0
    property int  pauseCount:       0
    property int  stopCount:        0
    property int  commandCount:     0
    property var  lastCommand:      undefined
    property int  setPropertyCount: 0
    property var  lastSetProperty:  ({ name: "", val: undefined })

    function play()                 { playCount  += 1 }
    function pause()                { pauseCount += 1 }
    function stop()                 { stopCount  += 1 }
    function command(cmd)           { commandCount += 1; lastCommand = cmd }
    function setProperty(name, val) { setPropertyCount += 1; lastSetProperty = { name: name, val: val } }

    signal firstFrame()
    signal sourceLoadFailed(string reason)
}
