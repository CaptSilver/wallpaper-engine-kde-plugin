import QtQuick
QtObject {
    property bool enabled: false
    property int  intervalMs: 33

    signal audioBuffer(var samples)

    function feedTestPcm(samples, channels) { return false }
    function runOneTick() {}
}
