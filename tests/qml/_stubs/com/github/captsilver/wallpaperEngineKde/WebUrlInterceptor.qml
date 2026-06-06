// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/WebUrlInterceptor.hpp + src/WebUrlInterceptor.cpp
// Last contract review: 2026-05-27

import QtQuick
// Test stub for the C++ WebUrlInterceptor (per-wallpaper file:// gate).
// Provides only the setWallpaperBaseDir method the production QtWebView
// calls during loadWallpaper(); no actual interception logic — the
// stub doesn't sit on a real QtWebEngine request path.
QtObject {
    property string baseDir: ""
    // Recorders for QML test assertions.
    property int    setBaseDirCount: 0
    property string lastBaseDir: ""
    property int    installOnCount: 0
    property var    lastInstalledProfile: null
    function setWallpaperBaseDir(dir) {
        baseDir = dir === undefined || dir === null ? "" : String(dir);
        setBaseDirCount += 1;
        lastBaseDir = baseDir;
    }
    // Production calls this from the WebEngineProfile's Component.onCompleted to
    // install the C++ interceptor (the real WebEngineProfile has no QML
    // urlRequestInterceptor property).  Record it so tests pin the wiring.
    function installOn(profile) {
        installOnCount += 1;
        lastInstalledProfile = profile;
    }
}
