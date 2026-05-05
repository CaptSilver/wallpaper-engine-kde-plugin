// Stub of wekde::PlaylistManager for QML tests. Doesn't persist anything;
// just satisfies the import + the Q_INVOKABLE / Q_PROPERTY surface area
// the production QML files expect.
import QtQuick

QtObject {
    property var playlistsModel: ListModel { }
    property string activePlaylistId: ""
    property int currentItemIndex: 0

    signal tick(string workshopId)
    signal requestFilteredPick()
    signal activationFailed(string id)
    signal persistFailed(string reason)

    function createPlaylist(name) { return "fake-uuid-" + name; }
    function deletePlaylist(id) { return true; }
    function renamePlaylist(id, name) { return true; }
    function setMode(id, mode) { return true; }
    function setIntervalMin(id, m) { return true; }
    function addItem(id, workshopId, dur) { return true; }
    function removeItem(id, idx) { return true; }
    function moveItem(id, fromIdx, toIdx) { return true; }
    function setItemDuration(id, idx, dur) { return true; }
    function activate(id) { return true; }
    function deactivate() { }
    function skipCurrent() { }
    function acceptPick(workshopId) { }
    function pauseTicks() { }
    function resumeTicks() { }
    function setFilteredLibraryIntervalMin(m) { }
    function itemsModel(id) {
        // Return a fresh empty list model each time. Not cached — tests that
        // mutate must use the production binary, not stubs.
        return Qt.createQmlObject('import QtQuick; ListModel{}', this);
    }
}
