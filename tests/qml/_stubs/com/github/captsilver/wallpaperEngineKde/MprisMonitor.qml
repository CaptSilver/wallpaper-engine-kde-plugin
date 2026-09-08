// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/MprisMonitor.hpp + src/MprisMonitor.cpp
// Last contract review: 2026-09-08
//
// tst_mpriscolors::qmlStubSurfaceMatchesTheRealMonitor diffs everything below
// against MprisMonitor's metaobject, so a member the real monitor does not
// declare fails the C++ suite.

import QtQuick
QtObject {
    // Production wrappers connect on these:
    signal playbackStateChanged(int state)
    signal propertiesChanged(string title, string artist, string albumTitle, string albumArtist, var genres, var duration)
    signal thumbnailChanged(bool hasThumbnail, var colors)
    signal timelineChanged(var position, var duration, int state)
    // Mirrors the real NOTIFY signal, argument included. The matching
    // `mediaAvailable` property can't live here too — QML would auto-generate
    // a second, parameterless mediaAvailableChanged for it.
    signal mediaAvailableChanged(bool available)

    // ── test recorders (test-only stub) ──────────────────────────────────
    property int  invokeShortcutCount: 0
    property var  lastShortcut:        undefined
    property int  engageCount:         0
    function invokeShortcut(name) { invokeShortcutCount += 1; lastShortcut = name }
    function engage()             { engageCount += 1 }
}
