import QtQuick
QtObject {
    property bool   enabled: false
    property bool   playing: false
    property string title:   ""
    property string artist:  ""
    property string artUrl:  ""
    property var    dominantColor: Qt.rgba(0, 0, 0, 1)

    // Production wrappers connect on these:
    signal playbackStateChanged(string state)
    signal propertiesChanged(string title, string artist, string albumTitle, string albumArtist, var genres, var duration)
    signal thumbnailChanged(bool hasThumbnail, var colors)
    signal timelineChanged(var position, var duration, int state)
    signal userShortcutRequested(string name)

    function invokeShortcut(name) {}
}
