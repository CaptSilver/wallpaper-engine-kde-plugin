// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/MigrationHelper.cpp
// Last contract review: 2026-05-27

pragma Singleton
import QtQuick
QtObject {
    function runIfNeeded() {}
    // First-launch seed of last_seen_version markers from the current
    // workshop manifest so the "updated" badge doesn't fire for every
    // existing wallpaper on first launch after the feature lands.
    function seedLastSeenVersions(manifest) {}
}
