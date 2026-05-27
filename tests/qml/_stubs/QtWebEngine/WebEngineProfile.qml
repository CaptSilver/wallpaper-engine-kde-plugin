// Stub — qmltestrunner doesn't ship Chromium.  Production binds the
// real WebEngineProfile's urlRequestInterceptor / offTheRecord / storageName;
// the stub mirrors those properties so the binding side-effects no-op.
import QtQuick
Item {
    property var    urlRequestInterceptor: null
    property bool   offTheRecord: false
    property string storageName: ""
}
