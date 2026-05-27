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
    function setWallpaperBaseDir(dir) {
        baseDir = dir === undefined || dir === null ? "" : String(dir);
        setBaseDirCount += 1;
        lastBaseDir = baseDir;
    }
}
