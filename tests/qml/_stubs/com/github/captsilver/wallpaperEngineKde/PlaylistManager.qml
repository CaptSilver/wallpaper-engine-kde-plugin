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

    // ── test recorders (test-only stub) ──────────────────────────────────
    property int  createPlaylistCount:    0
    property var  lastCreatePlaylistName: undefined
    property int  deletePlaylistCount:    0
    property var  lastDeletePlaylistId:   undefined
    property int  renamePlaylistCount:    0
    property var  lastRenamePlaylistArgs: ({ id: "", name: "" })
    property int  setModeCount:           0
    property var  lastSetModeArgs:        ({ id: "", mode: 0 })
    property int  setIntervalMinCount:    0
    property var  lastSetIntervalMinArgs: ({ id: "", m: 0 })
    property int  addItemCount:           0
    property var  lastAddItemArgs:        ({ id: "", workshopId: "" })
    property int  removeItemCount:        0
    property var  lastRemoveItemArgs:     ({ id: "", idx: 0 })
    property int  moveItemCount:          0
    property var  lastMoveItemArgs:       ({ id: "", fromIdx: 0, toIdx: 0 })
    property int  activateCount:          0
    property var  lastActivateId:         undefined
    property int  deactivateCount:        0
    property int  skipCurrentCount:       0
    property int  acceptPickCount:        0
    property var  lastAcceptPickArg:      undefined
    property int  pauseTicksCount:        0
    property int  resumeTicksCount:       0
    property int  setFilteredLibraryIntervalMinCount: 0
    property var  lastSetFilteredLibraryIntervalMinArg: undefined
    property int  reloadCount:            0
    property int  playlistContainsCount:  0

    function createPlaylist(name) {
        createPlaylistCount += 1;
        lastCreatePlaylistName = name;
        return "fake-uuid-" + name;
    }
    function deletePlaylist(id) {
        deletePlaylistCount += 1;
        lastDeletePlaylistId = id;
        // Mirror the C++ deactivate-first behavior: if the user deletes
        // the currently-active playlist, drop the active id so the
        // controller's onActivePlaylistIdChanged handler fires.
        if (activePlaylistId === id) activePlaylistId = "";
        return true;
    }
    function renamePlaylist(id, name) {
        renamePlaylistCount += 1;
        lastRenamePlaylistArgs = { id: id, name: name };
        return true;
    }
    function setMode(id, mode) {
        setModeCount += 1;
        lastSetModeArgs = { id: id, mode: mode };
        return true;
    }
    function setIntervalMin(id, m) {
        setIntervalMinCount += 1;
        lastSetIntervalMinArgs = { id: id, m: m };
        return true;
    }
    function addItem(id, workshopId) {
        addItemCount += 1;
        lastAddItemArgs = { id: id, workshopId: workshopId };
        return true;
    }
    function removeItem(id, idx) {
        removeItemCount += 1;
        lastRemoveItemArgs = { id: id, idx: idx };
        return true;
    }
    function moveItem(id, fromIdx, toIdx) {
        moveItemCount += 1;
        lastMoveItemArgs = { id: id, fromIdx: fromIdx, toIdx: toIdx };
        return true;
    }
    // Stub: always returns false. Tests that exercise the "already
    // added" UI branch should mock this with a richer implementation.
    function playlistContains(id, workshopId) { playlistContainsCount += 1; return false; }
    function activate(id) {
        activateCount += 1;
        lastActivateId = id;
        // Track state minimally so deletePlaylist's "deactivate first if
        // currently active" path can fire activePlaylistIdChanged.
        if (activePlaylistId !== id) activePlaylistId = id;
        return true;
    }
    function deactivate() {
        deactivateCount += 1;
        activePlaylistId = "";
    }
    function skipCurrent() { skipCurrentCount += 1; }
    function acceptPick(workshopId) { acceptPickCount += 1; lastAcceptPickArg = workshopId; }
    function pauseTicks() { pauseTicksCount += 1; }
    function resumeTicks() { resumeTicksCount += 1; }
    function setFilteredLibraryIntervalMin(m) {
        setFilteredLibraryIntervalMinCount += 1;
        lastSetFilteredLibraryIntervalMinArg = m;
    }
    function reload() { reloadCount += 1; }
    function itemsModel(id) {
        // Return a fresh empty list model each time. Not cached — tests that
        // mutate must use the production binary, not stubs.
        return Qt.createQmlObject('import QtQuick; ListModel{}', this);
    }
}
