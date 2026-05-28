// Stub of the C++ WekControl class for QML test harnesses.
//
// Production: registers a session-bus service that exposes Next / Previous /
// Pause / etc. and emits WallpaperChanged on every transition.  In tests
// the bus surface is irrelevant -- the QML tests only care that the
// emitWallpaperChanged hook is callable and that setPlaylistController is
// a no-op (the routing is exercised in tst_wekcontrol.cpp).
import QtQuick

QtObject {
    // Recorded values so tests can assert the last emission.
    property string lastEmittedWorkshopId: ""
    property string lastEmittedPlaylistId: ""

    function setPlaylistController(controller) {
        // No-op in tests: the C++ adapter routes via QMetaObject in the real
        // build; QML stubs don't need the round-trip.
    }

    function emitWallpaperChanged(workshopId, playlistId) {
        lastEmittedWorkshopId = workshopId;
        lastEmittedPlaylistId = playlistId;
    }
}
