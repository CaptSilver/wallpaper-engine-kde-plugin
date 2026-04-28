// Stub for the Vulkan-backed SceneViewer plugin type. Quick3D / Vulkan can't
// run in qmltestrunner offscreen; we just provide the QML API surface that
// production wrappers (backend/Scene.qml) talk to.
import QtQuick
Item {
    enum FillMode { STRETCH, ASPECTFIT, ASPECTCROP }

    property string source:         ""
    property string assets:         "assets"
    property int    fps:            30
    property real   speed:          1.0
    property int    displayMode:    0
    property int    fillMode:       SceneViewer.ASPECTFIT
    property string userProperties: ""
    property bool   muted:          false
    property real   volume:         1.0
    property bool   stats:          false
    property bool   mouseInput:     true
    property bool   hdrOutput:      false
    property bool   systemAudioCapture: false

    signal firstFrame()
    signal userShortcutRequested(string name)
    signal mediaPlaybackChanged(string state)
    signal mediaPropertiesChanged(string title, string artist, string albumTitle, string albumArtist, var genres)
    signal mediaThumbnailChanged(bool hasThumbnail, var colors)
    signal mediaTimelineChanged(var position, var duration)
    signal mediaStatusChanged(bool enabled)

    function play()                 {}
    function pause()                {}
    function setAcceptMouse(b)      {}
    function setAcceptHover(b)      {}
}
