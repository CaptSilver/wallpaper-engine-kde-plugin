// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: Qt 6 QtWebEngine docs (type-import placeholder)
// Last contract review: 2026-05-27

// Stub — qmltestrunner doesn't ship Chromium.  Production binds the
// real WebEngineProfile's urlRequestInterceptor / offTheRecord / storageName;
// the stub mirrors those properties so the binding side-effects no-op.
import QtQuick
Item {
    property var    urlRequestInterceptor: null
    property bool   offTheRecord: false
    property string storageName: ""
}
