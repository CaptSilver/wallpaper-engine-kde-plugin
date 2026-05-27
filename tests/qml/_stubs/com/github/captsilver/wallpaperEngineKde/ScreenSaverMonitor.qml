// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/ScreenSaverMonitor.hpp + src/ScreenSaverMonitor.cpp
// Last contract review: 2026-05-27

import QtQuick
QtObject {
    // Production signal is `screenSaverActiveChanged(bool)` and is used as
    // the NOTIFY for the `active` property. The tests poke `active`
    // directly; the binding chain handles the notify.
    property bool active: false
    signal screenSaverActiveChanged(bool active)
}
