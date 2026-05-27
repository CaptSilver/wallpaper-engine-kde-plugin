// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: plasma5support (Plasma 6 framework)
// Last contract review: 2026-05-27

import QtQuick
QtObject {
    property var sourceModel: null
    property string filterRole: ""
    property string filterRegExp: ""
    property string sortRole: ""
    property int sortOrder: Qt.AscendingOrder
    property int count: 0
    signal dataChanged()  // production code uses `onDataChanged`
}
