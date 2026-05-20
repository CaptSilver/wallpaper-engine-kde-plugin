// Visual stand-in for main.qml's root `background` Rectangle in letterbox
// integration tests. Unlike BackgroundFake (a non-visual QtObject used by the
// backend-wrapper unit tests), this is a real Rectangle whose `color` is the
// backdrop that must show through the Keep-Aspect letterbox bars, and whose
// width/height simulate ONE screen's wallpaper area (set them per geometry).
// backend/Scene.qml resolves the unqualified `background` id via parent scope,
// so place a Backend.Scene as a child and give this an `id: background`.
import QtQuick
Rectangle {
    color: "#808080"   // backdrop colour (main.qml binds Rectangle.color to background.backgroundColor)

    // ---- the `background.*` surface backend/Scene.qml reads ----------------
    property int    displayMode:        0      // Common.DisplayMode.Aspect
    property string userPropsJson:      ""
    property bool   mute:               false
    property real   volume:             50
    property real   speed:              1.0
    property int    fps:                30
    property bool   hdrOutput:          false
    property string postProcessing:     ""
    property bool   systemAudioCapture: false
    property string nowBackend:         ""

    signal sig_backendFirstFrame(string name)
}
