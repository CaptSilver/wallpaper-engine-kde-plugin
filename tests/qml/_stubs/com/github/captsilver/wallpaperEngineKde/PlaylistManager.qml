// Stub of wekde::PlaylistManager for QML tests. Doesn't persist anything;
// just satisfies the import + the Q_INVOKABLE / Q_PROPERTY surface area
// the production QML files expect.
import QtQuick

QtObject {
    property var playlistsModel: ListModel { }
    property string activePlaylistId: ""
    property int currentItemIndex: 0
    // Mirrors the real C++ Q_PROPERTY so production QML files (and tests
    // exercising the editor-vs-runtime split) can bind it.
    property bool editorMode: false

    signal tick(string workshopId)
    signal requestFilteredPick()
    signal activationFailed(string id)
    signal persistFailed(string reason)
    signal persisted()

    function createPlaylist(name) { return "fake-uuid-" + name; }
    function deletePlaylist(id) {
        // Mirror the C++ deactivate-first behavior: if the user deletes
        // the currently-active playlist, drop the active id so the
        // controller's onActivePlaylistIdChanged handler fires.
        if (activePlaylistId === id) activePlaylistId = "";
        return true;
    }
    function renamePlaylist(id, name) { return true; }
    function setMode(id, mode) { return true; }
    function setIntervalMin(id, m) { return true; }
    function addItem(id, workshopId) { return true; }
    function removeItem(id, idx) { return true; }
    function moveItem(id, fromIdx, toIdx) { return true; }
    // Stub: always returns false. Tests that exercise the "already
    // added" UI branch should mock this with a richer implementation.
    function playlistContains(id, workshopId) { return false; }
    function activate(id) {
        // Track state minimally so deletePlaylist's "deactivate first if
        // currently active" path can fire activePlaylistIdChanged.
        if (activePlaylistId !== id) activePlaylistId = id;
        return true;
    }
    function deactivate() { activePlaylistId = ""; }
    function skipCurrent() { }
    function acceptPick(workshopId) { }
    function pauseTicks() { }
    function resumeTicks() { }
    function setFilteredLibraryIntervalMin(m) { }
    function reload() { }
    function itemsModel(id) {
        // Return a fresh empty list model each time. Not cached — tests that
        // mutate must use the production binary, not stubs.
        return Qt.createQmlObject('import QtQuick; ListModel{}', this);
    }
}
