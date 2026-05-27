// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: src/FileHelper.hpp + src/FileHelper.cpp
// Last contract review: 2026-05-27

// Test stub for the C++ FileHelper QML type. Methods return canned values
// or empty objects so production code can run through happy paths in tests.
import QtQuick
QtObject {
    id: stub
    property var _readReturns: ""
    property var _patchedHtmlReturns: ""
    property var _scanVideoFolderReturns: []
    property var _wallpaperConfigReturns: ({})

    signal thumbnailReady(string videoPath, string outPath, bool ok)
    signal dirSizeReady(string path, real bytes)

    // ── test recorders (test-only stub) ──────────────────────────────────
    property int  readFileCount:              0
    property var  lastReadFilePath:           undefined
    property int  patchedHtmlCount:           0
    property var  lastPatchedHtmlPath:        undefined
    property int  getDirSizeCount:            0
    property int  getFolderListCount:         0
    property int  readWallpaperConfigCount:   0
    property var  lastReadWallpaperConfigId:  undefined
    property int  writeWallpaperConfigCount:  0
    property var  lastWriteWallpaperConfigArgs: ({ id: "", cfg: undefined })
    property int  resetWallpaperConfigCount:  0
    property var  lastResetWallpaperConfigId: undefined
    property int  readActiveBindingsCount:    0
    property int  scanVideoFolderCount:       0
    property int  clearCacheDirCount:         0
    property var  lastClearCacheDirPath:      undefined
    property int  generateThumbnailCount:     0
    property var  lastGenerateThumbnailArgs:  ({ videoPath: "", outPath: "", atSeconds: 0 })
    property int  requestDirSizeCount:        0
    property var  lastRequestDirSizeArgs:     ({ path: "", depth: 0 })
    property int  addReadRootCount:           0
    property var  lastAddReadRootPath:        undefined
    property int  clearReadRootsCount:        0

    function readFile(path)              { readFileCount += 1; lastReadFilePath = path; return _readReturns; }
    function patchedHtml(path)           { patchedHtmlCount += 1; lastPatchedHtmlPath = path; return _patchedHtmlReturns; }
    function qwebChannelSource()         { return ""; }
    function getDirSize(path, depth)     { getDirSizeCount += 1; return 0; }
    function getFolderList(path, opt)    { getFolderListCount += 1; return []; }
    function readWallpaperConfig(id)     {
        readWallpaperConfigCount += 1;
        lastReadWallpaperConfigId = id;
        return _wallpaperConfigReturns;
    }
    function writeWallpaperConfig(id, c) {
        writeWallpaperConfigCount += 1;
        lastWriteWallpaperConfigArgs = { id: id, cfg: c };
    }
    function resetWallpaperConfig(id)    {
        resetWallpaperConfigCount += 1;
        lastResetWallpaperConfigId = id;
    }
    function readActiveBindings(id)      { readActiveBindingsCount += 1; return []; }
    function scanVideoFolder(path)       { scanVideoFolderCount += 1; return _scanVideoFolderReturns; }
    // Always reports success in tests. Real impl refuses paths outside the
    // user's cache root; tests that need to exercise the refusal path
    // should mock this directly.
    function clearCacheDir(path)         {
        clearCacheDirCount += 1;
        lastClearCacheDirPath = path;
        return true;
    }
    function generateThumbnail(videoPath, outPath, atSeconds) {
        generateThumbnailCount += 1;
        lastGenerateThumbnailArgs = { videoPath: videoPath, outPath: outPath, atSeconds: atSeconds };
        // Fire the signal synchronously in the stub so tests can resolve
        // promises immediately without a QSignalSpy/wait.
        Qt.callLater(() => stub.thumbnailReady(videoPath, outPath, true));
    }
    // Fire dirSizeReady via callLater so get_dir_size's promise resolves without
    // a QSignalSpy/wait (mirrors the generateThumbnail stub).
    function requestDirSize(path, depth) {
        requestDirSizeCount += 1;
        lastRequestDirSizeArgs = { path: path, depth: depth };
        Qt.callLater(() => stub.dirSizeReady(path, 0));
    }
    function addReadRoot(path) {
        addReadRootCount += 1;
        lastAddReadRootPath = path;
    }
    function clearReadRoots() {
        clearReadRootsCount += 1;
    }
}
