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
    signal fileReadReady(string path, var contents, bool ok)
    signal wallpaperDirChanged(string path)

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
    property int  requestReadFileCount:       0
    property var  lastRequestReadFilePath:    undefined
    property int  watchWallpaperDirCount:     0
    property var  lastWatchWallpaperDirPath:  undefined
    property int  unwatchAllWallpaperDirsCount: 0
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
    // Fire fileReadReady via callLater so readfile()'s promise resolves
    // without a QSignalSpy/wait (mirrors the generateThumbnail / requestDirSize
    // stubs). Returns _readReturns as the contents and ok=true so production
    // code traverses the success branch.
    function requestReadFile(path) {
        requestReadFileCount += 1;
        lastRequestReadFilePath = path;
        Qt.callLater(() => stub.fileReadReady(path, _readReturns, true));
    }
    function watchWallpaperDir(path) {
        watchWallpaperDirCount += 1;
        lastWatchWallpaperDirPath = path;
    }
    function unwatchAllWallpaperDirs() {
        unwatchAllWallpaperDirsCount += 1;
    }
    function addReadRoot(path) {
        addReadRootCount += 1;
        lastAddReadRootPath = path;
    }
    function clearReadRoots() {
        clearReadRootsCount += 1;
    }

    // ── workshop-update detection (test stubs return empty maps) ──────────
    property var _workshopManifestReturns: ({})
    property var _allSeenVersionsReturns:  ({})
    property int  readWorkshopManifestCount:  0
    property var  lastReadWorkshopManifestPath: undefined
    property int  allSeenVersionsCount:       0
    property int  recordSeenVersionCount:     0
    property var  lastRecordSeenVersionArgs:  ({ id: "", version: 0 })
    property int  seenVersionCount:           0
    property var  lastSeenVersionId:          undefined
    property int  pruneOrphanThumbnailsCount: 0
    property int  enforceCacheQuotaCount:     0

    function readWorkshopManifest(steamLibraryPath) {
        readWorkshopManifestCount += 1;
        lastReadWorkshopManifestPath = steamLibraryPath;
        return _workshopManifestReturns;
    }
    function allSeenVersions() {
        allSeenVersionsCount += 1;
        return _allSeenVersionsReturns;
    }
    function recordSeenVersion(id, version) {
        recordSeenVersionCount += 1;
        lastRecordSeenVersionArgs = { id: id, version: version };
    }
    function seenVersion(id) {
        seenVersionCount += 1;
        lastSeenVersionId = id;
        return 0;
    }
    function pruneOrphanThumbnails(cacheRoot, manifestIds) {
        pruneOrphanThumbnailsCount += 1;
        return 0;
    }
    function enforceCacheQuota(roots, quotaBytes) {
        enforceCacheQuotaCount += 1;
        return 0;
    }
    function enforceCacheQuotaForce(roots, quotaBytes) {
        enforceCacheQuotaCount += 1;
        return 0;
    }

    // Last GC bytes-freed status — exposed to the SettingPage Text binding
    // under the "Run cache GC now" button so the user sees the freed
    // count without polling.
    property real lastGcBytesFreed: 0
}
