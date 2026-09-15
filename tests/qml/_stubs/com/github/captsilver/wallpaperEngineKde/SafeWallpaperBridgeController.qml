// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/SafeWallpaperBridgeController.hpp + .cpp
// Last contract review: 2026-09-15

import QtQuick
// Test stub for the C++ SafeWallpaperBridgeController — the QML-only object
// that forwards setLoaded/push* onto a SafeWallpaperBridge sibling. In the
// real plugin these are Q_INVOKABLE (QML can call them, QWebChannel never
// sees this type at all); a plain QML stub can't reproduce that C++
// invokability distinction, so the forwarding is what this stub actually
// pins — production QML must call through here, not assign to the bridge's
// (read-only) properties directly.
QtObject {
    id: controller

    property var bridge: null

    function setLoaded(v) {
        if (bridge) bridge.setLoaded(v);
    }
    function pushUserProperties(m) {
        if (bridge) bridge.pushUserProperties(m);
    }
    function pushGeneralProperties(m) {
        if (bridge) bridge.pushGeneralProperties(m);
    }
}
