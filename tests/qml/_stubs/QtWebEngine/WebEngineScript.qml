// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: Qt 6 QtWebEngine docs (type-import placeholder)
// Last contract review: 2026-05-27

import QtQuick
QtObject {
    enum InjectionPoint  { DocumentCreation, DocumentReady, Deferred }
    enum WorldId         { MainWorld, ApplicationWorld, UserWorld }
    property string sourceCode: ""
    property string sourceUrl:  ""
    property string name:       ""
    property int    injectionPoint: 0
    property int    worldId:        0
    property bool   runOnSubframes: false
}
