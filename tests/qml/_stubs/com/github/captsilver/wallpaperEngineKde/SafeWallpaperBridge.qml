// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/SafeWallpaperBridge.hpp + src/SafeWallpaperBridge.cpp
// Last contract review: 2026-05-27

import QtQuick
// Test stub for the C++ SafeWallpaperBridge. Mirrors the production surface:
//   * generalProperties / userProperties / loaded are exposed (writable here
//     for stub-internal mutation by the setters; the production C++ properties
//     are READ-only over QWebChannel — the setters are the only mutation path
//     that fires the NOTIFY chain consistently).
//   * pushGeneralProperties / pushUserProperties / setLoaded are functions
//     (matching the C++ public methods, NOT Q_INVOKABLE — QML reaches them
//     via the type system).
//   * sigGeneralProperties / sigUserProperties / sigAudio / sigInit are
//     signals that wallpaper JS subscribes to over QWebChannel.
//   * loadedChanged is auto-emitted by the QML engine for the `loaded`
//     property; setLoaded routes through it + drives sigInit one-shot
//     semantics.
QtObject {
    id: bridge

    // Backing fields — writable internally; expose READ-only views.
    property var  _generalProperties: ({})
    property var  _userProperties:    ({})
    property bool _loaded:            false
    // One-shot init guard — matches the C++ m_initFired.
    property bool _initFired:         false

    // READ-only views — match the production C++ Q_PROPERTY surface
    // (READ only, no WRITE = JS-side assignments through QWebChannel
    // silently no-op; QML direct writes raise "Cannot assign to non-writable
    // property" warnings).
    readonly property var  generalProperties: _generalProperties
    readonly property var  userProperties:    _userProperties
    readonly property bool loaded:            _loaded

    signal sigGeneralProperties(var properties)
    signal sigUserProperties(var properties)
    signal sigAudio(var samples)
    signal sigInit()

    function pushGeneralProperties(m) {
        _generalProperties = m;
        sigGeneralProperties(m);
    }
    function pushUserProperties(m) {
        _userProperties = m;
        sigUserProperties(m);
    }
    function setLoaded(v) {
        if (_loaded === v) return;
        _loaded = v;
        if (v && !_initFired) {
            _initFired = true;
            sigInit();
        }
    }
}
