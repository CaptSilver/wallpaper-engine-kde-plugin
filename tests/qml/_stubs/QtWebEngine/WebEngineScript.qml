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
