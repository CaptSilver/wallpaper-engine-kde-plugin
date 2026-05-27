// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/TTYSwitchMonitor.hpp + src/TTYSwitchMonitor.cpp
// Last contract review: 2026-05-27

import QtQuick
QtObject {
    // main.qml uses `onTtySwitch: { if (sleep) ... else ... }` — the
    // signal carries a `sleep` arg.
    signal ttySwitch(bool sleep)
}
