// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/WebAudioBridge.hpp + src/WebAudioBridge.cpp
// Last contract review: 2026-05-27

import QtQuick
QtObject {
    property bool enabled: false
    property int  intervalMs: 33

    signal audioBuffer(var samples)

    function feedTestPcm(samples, channels) { return false }
    function runOneTick() {}
}
