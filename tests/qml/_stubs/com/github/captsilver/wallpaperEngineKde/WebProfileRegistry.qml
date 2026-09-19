// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/WebProfileRegistry.hpp + src/WebProfileRegistry.cpp
// Last contract review: 2026-09-19

import QtQuick
import com.github.captsilver.wallpaperEngineKde 1.2

// Thin per-instance facade over WebProfileRegistryStore, the same shape as
// the real class: every WebProfileRegistry {} element a test creates
// forwards to the one store, so "same workshop id -> same profile object"
// holds regardless of which element asked.
QtObject {
    function storageNameFor(workshopId) { return WebProfileRegistryStore.storageNameFor(workshopId); }
    function profileFor(workshopId)     { return WebProfileRegistryStore.profileFor(workshopId); }
    function interceptorFor(workshopId) { return WebProfileRegistryStore.interceptorFor(workshopId); }
    function liveProfileCount()         { return WebProfileRegistryStore.liveProfileCount(); }
}
