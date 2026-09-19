// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/WebProfileRegistry.hpp + src/WebProfileRegistry.cpp
// Last contract review: 2026-09-19

pragma Singleton
import QtQuick
import "WebProfileRegistryData.js" as Data

// One instance per QML engine (qmltestrunner starts a fresh engine per test
// file, matching how production shares one process-wide table across every
// engine it runs in) -- every WebProfileRegistry {} element in a test reads
// and writes through this same object, so two elements asking for the same
// workshop id get the same stub profile, exactly like the real class.
//
// The actual cache and call log live in WebProfileRegistryData.js, a
// .pragma library module, not as properties on this object -- see that
// file's header comment for why (a property here would leak into other
// bindings' dependency graphs in a way the real C++ class never can).
QtObject {
    id: store

    function storageNameFor(workshopId) { return Data.storageNameFor(workshopId); }
    function profileFor(workshopId)     { return Data.profileFor(workshopId, store); }
    function interceptorFor(workshopId) { return Data.interceptorFor(workshopId, store); }
    function liveProfileCount()         { return Data.liveProfileCount(); }

    // Test seams: which workshop ids profileFor() was actually asked for,
    // and resetting that log between assertions.
    function callsSnapshot() { return Data.callsSnapshot(); }
    function resetCalls()    { Data.resetCalls(); }
}
