// Stub of the C++ WekNotifier class for QML test harnesses.
//
// Production: fires KNotification entries from the event groups in
// wek.notifyrc (wallpaperLoadFailed / playlistAdvanced / assetsMissing /
// backendUnavailable). Tests only need to confirm the QML caller routes
// to the right method with the right args; KF6::Notifications is not
// available in the test environment.
import QtQuick

QtObject {
    property string lastEvent: ""
    property var    lastArgs: []

    function wallpaperLoadFailed(workshopId, reason) {
        lastEvent = "wallpaperLoadFailed";
        lastArgs = [workshopId, reason];
    }

    function playlistAdvanced(workshopId, title, itemIndex, totalItems, playlistName) {
        lastEvent = "playlistAdvanced";
        lastArgs = [workshopId, title, itemIndex, totalItems, playlistName];
    }

    function assetsMissing(workshopId, path) {
        lastEvent = "assetsMissing";
        lastArgs = [workshopId, path];
    }

    function backendUnavailable(backendName, reason) {
        lastEvent = "backendUnavailable";
        lastArgs = [backendName, reason];
    }
}
