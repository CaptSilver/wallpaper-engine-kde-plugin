// Test stub for the C++ FileHelper QML type. Methods return canned values
// or empty objects so production code can run through happy paths in tests.
import QtQuick
QtObject {
    id: stub
    property var _readReturns: ""
    property var _patchedHtmlReturns: ""
    property var _scanVideoFolderReturns: []

    signal thumbnailReady(string videoPath, string outPath, bool ok)

    function readFile(path)              { return _readReturns; }
    function patchedHtml(path)           { return _patchedHtmlReturns; }
    function qwebChannelSource()         { return ""; }
    function getDirSize(path, depth)     { return 0; }
    function getFolderList(path, opt)    { return []; }
    function readWallpaperConfig(id)     { return ({}); }
    function writeWallpaperConfig(id, c) { return; }
    function resetWallpaperConfig(id)    { return; }
    function readActiveBindings(id)      { return ({}); }
    function scanVideoFolder(path)       { return _scanVideoFolderReturns; }
    // Always reports success in tests. Real impl refuses paths outside the
    // user's cache root; tests that need to exercise the refusal path
    // should mock this directly.
    function clearCacheDir(path)         { return true; }
    function generateThumbnail(videoPath, outPath, atSeconds) {
        // Fire the signal synchronously in the stub so tests can resolve
        // promises immediately without a QSignalSpy/wait.
        Qt.callLater(() => stub.thumbnailReady(videoPath, outPath, true));
    }
}
