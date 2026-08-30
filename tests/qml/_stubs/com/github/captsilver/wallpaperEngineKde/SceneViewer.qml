// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/plugin.cpp registers scenebackend::SceneObject (src/backend_scene/qml_helper/)
// Last contract review: 2026-05-27

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
    property string postprocessingOverride: ""  // wallpaper-default when empty
    property bool   systemAudioCapture: false
    property int    presentMode:    0    // Swapchain present-mode policy (Auto=0)
    property int    outputRefreshMillihertz: 60000  // millihertz (59.94Hz -> 59940)
    property real   nativeAspectRatio:  0  // 0 = scene not loaded yet (real type's sentinel)

    signal firstFrame()
    signal userShortcutRequested(string name)
    signal mediaPlaybackChanged(string state)
    // arities mirror the C++ SceneObject::media*Changed Q_INVOKABLEs and the
    // production routes in plugin/contents/ui/backend/Scene.qml.
    signal mediaPropertiesChanged(string title, string artist, string albumTitle, string albumArtist, var genres, var duration)
    signal mediaThumbnailChanged(bool hasThumbnail, var colors)
    signal mediaTimelineChanged(var position, var duration, int state)
    signal mediaStatusChanged(bool enabled)
    signal videoDecodeFailed(string summary)

    // ── test recorders (test-only stub) ──────────────────────────────────
    // Production wrappers call these imperatively; recording call-count and
    // last-arg here lets converted verify(true) sites assert observable
    // effect (compare(player.playCount, n+1)) instead of just "did not
    // throw." Signal-based forwards (media*Changed) are observed via
    // SignalSpy on the corresponding signals declared above.
    property int  playCount:       0
    property int  pauseCount:      0
    property var  lastAcceptMouse: undefined
    property var  lastAcceptHover: undefined

    function play()                 { playCount  += 1 }
    function pause()                { pauseCount += 1 }
    function setAcceptMouse(b)      { lastAcceptMouse = b }
    function setAcceptHover(b)      { lastAcceptHover = b }
}
