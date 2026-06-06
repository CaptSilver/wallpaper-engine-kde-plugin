// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: Qt 6 QtWebEngine docs (type-import placeholder)
// Last contract review: 2026-06-05

// Stub — qmltestrunner doesn't ship Chromium.  Production binds the
// real WebEngineProfile's offTheRecord / storageName / httpCacheType /
// httpCacheMaximumSize; the stub mirrors those properties so the binding
// side-effects no-op.  Property NAMES must match the real QQuickWebEngineProfile
// exactly — a stub that mirrors a typo'd or non-existent name lets a
// non-existent-property bug pass the QML tests yet break at runtime (that is
// exactly how both httpCacheMaxSize and urlRequestInterceptor shipped; the real
// type has NO urlRequestInterceptor property — interception is wired in C++ via
// setUrlRequestInterceptor()).  HttpCacheType enum values mirror the Qt 6
// QQuickWebEngineProfile HTTP cache type enum.
import QtQuick
Item {
    enum HttpCacheType { MemoryHttpCache, DiskHttpCache, NoCache }

    property bool   offTheRecord: false
    property string storageName: ""
    property int    httpCacheType: WebEngineProfile.DiskHttpCache
    property int    httpCacheMaximumSize: 0
}
