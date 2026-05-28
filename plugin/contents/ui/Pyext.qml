import QtQuick 2.0
import com.github.captsilver.wallpaperEngineKde 1.2

// FileHelper wrapper with Promise-like API for backwards compatibility
Item {
    id: root

    // Always ready (no Python startup delay)
    readonly property bool ok: true
    readonly property string log: ""
    readonly property string version: "native"

    // Forwarded from FileHelper::wallpaperDirChanged. The QML-side
    // WallpaperListModel attaches a Connection + 500 ms debounce Timer and
    // calls refresh() on each settle.
    signal wallpaperDirChanged(string path)

    // Internal C++ FileHelper instance
    FileHelper {
        id: fileHelper
    }

    // QML-supplied allowlist for fileHelper.readFile. Each entry is a
    // native filesystem path (file:// stripped on the C++ side, but
    // pre-stripped via Common.urlNative by all upstream callers anyway).
    // Empty array => permissive back-compat (first-run, no settings).
    // The instantiating QML (main.qml / config.qml) reassigns on every
    // settings change that should widen or narrow the surface (e.g.
    // SteamLibraryPath or VideoFolderPath edits).
    property var seedRoots: []

    onSeedRootsChanged: {
        fileHelper.clearReadRoots();
        for (var i = 0; i < seedRoots.length; i++) {
            var r = seedRoots[i];
            if (r && r.length > 0) fileHelper.addReadRoot(r);
        }
    }

    // Promise-like wrapper for synchronous calls
    function _makePromise(value) {
        return {
            result: value,
            then: function(callback) {
                const res = callback(value);
                // Return chainable promise
                return _makePromise(res !== undefined ? res : value);
            },
            catch: function(callback) {
                // No-op for synchronous calls (errors would throw immediately)
                return _makePromise(value);
            }
        };
    }

    function qwebChannelSource() {
        return fileHelper.qwebChannelSource();
    }

    function patchedHtml(path) {
        return fileHelper.patchedHtml(path);
    }

    function readfile(path) {
        // Async: fileHelper.requestReadFile dispatches to the per-instance
        // QThreadPool and resolves via onFileReadReady. Coalescing: multiple
        // concurrent callers for the same path share one C++ request through
        // root._readWaiters.
        return new Promise((resolve, reject) => {
            if (! root._readWaiters[path])
                root._readWaiters[path] = [];
            root._readWaiters[path].push({ resolve: resolve, reject: reject });
            fileHelper.requestReadFile(path);
        });
    }

    function get_dir_size(path, depth) {
        if (depth === undefined) depth = 3;
        // Async: requestDirSize runs the walk off the GUI thread and resolves via
        // onDirSizeReady, so a multi-GB cache tree never blocks the compositor.
        return new Promise((resolve) => {
            if (! root._dirSizeWaiters[path])
                root._dirSizeWaiters[path] = [];
            root._dirSizeWaiters[path].push(resolve);
            fileHelper.requestDirSize(path, depth);
        });
    }

    function get_folder_list(path, opt) {
        if (opt === undefined) opt = {};
        const result = fileHelper.getFolderList(path, opt);
        return _makePromise(result);
    }

    function read_wallpaper_config(id) {
        const config = fileHelper.readWallpaperConfig(id);
        return _makePromise(config);
    }

    function write_wallpaper_config(id, changed) {
        fileHelper.writeWallpaperConfig(id, changed);
        return _makePromise(null);
    }

    function reset_wallpaper_config(id) {
        fileHelper.resetWallpaperConfig(id);
        return _makePromise(null);
    }

    function read_active_bindings(id) {
        const bindings = fileHelper.readActiveBindings(id);
        return _makePromise(bindings);
    }

    function scan_video_folder(path) {
        const list = fileHelper.scanVideoFolder(path);
        return _makePromise(list);
    }

    function clear_cache(path) {
        const ok = fileHelper.clearCacheDir(path);
        return _makePromise(ok);
    }

    function watch_wallpaper_dir(path)    { fileHelper.watchWallpaperDir(path); }
    function unwatch_all_wallpaper_dirs() { fileHelper.unwatchAllWallpaperDirs(); }

    // Cache GC + quota helpers (GAP-8). Synchronous on C++ side — small dirs;
    // future async dispatch via QThreadPool is straightforward if needed.
    function prune_orphan_thumbnails(cacheRoot, installedDirs, videoDirs) {
        return fileHelper.pruneOrphanThumbnails(cacheRoot, installedDirs || [], videoDirs || []);
    }
    function enforce_cache_quota(roots, quotaBytes) {
        return fileHelper.enforceCacheQuota(roots || [], quotaBytes);
    }
    function enforce_cache_quota_force(roots, quotaBytes) {
        return fileHelper.enforceCacheQuotaForce(roots || [], quotaBytes);
    }
    // Steam Workshop manifest helpers (GAP-9). Synchronous reads; the .acf
    // is ~tens of KB for a few hundred items.
    function read_workshop_manifest(steamLibraryPath) {
        return fileHelper.readWorkshopManifest(steamLibraryPath);
    }
    function all_seen_versions() {
        return fileHelper.allSeenVersions();
    }
    function record_seen_version(id, timeUpdated) {
        fileHelper.recordSeenVersion(id, timeUpdated);
    }

    // Expose the underlying FileHelper so QML can bind to its
    // Q_PROPERTY values (e.g. lastGcBytesFreed for the SettingPage readout).
    // Read-only — callers should still go through this wrapper for the
    // promise-shaped API.
    readonly property alias helper: fileHelper

    // Pending thumbnail requests keyed by videoPath. Each entry is an array of
    // {resolve, reject, outPath} callbacks waiting on the next thumbnailReady
    // signal matching that videoPath.
    property var _thumbWaiters: ({})
    // Pending getDirSize requests keyed by absolute path. Each entry is an array
    // of resolve callbacks waiting on the next dirSizeReady for that path.
    property var _dirSizeWaiters: ({})
    // Pending readfile requests keyed by path. Each entry is an array of
    // {resolve, reject} callbacks. Multiple concurrent callers for the same
    // path coalesce onto ONE C++ requestReadFile.
    property var _readWaiters: ({})

    function generate_thumbnail(videoPath, outPath, atSeconds) {
        return new Promise((resolve, reject) => {
            if (! root._thumbWaiters[videoPath])
                root._thumbWaiters[videoPath] = [];
            root._thumbWaiters[videoPath].push({ resolve: resolve, reject: reject, outPath: outPath });
            fileHelper.generateThumbnail(videoPath, outPath, atSeconds);
        });
    }

    Connections {
        target: fileHelper
        function onThumbnailReady(videoPath, outPath, ok) {
            const waiters = root._thumbWaiters[videoPath] || [];
            delete root._thumbWaiters[videoPath];
            for (let i = 0; i < waiters.length; i++) {
                const w = waiters[i];
                if (ok) w.resolve(outPath);
                else w.reject(new Error("thumbnail generation failed: " + videoPath));
            }
        }
        function onDirSizeReady(path, bytes) {
            const waiters = root._dirSizeWaiters[path] || [];
            delete root._dirSizeWaiters[path];
            for (let i = 0; i < waiters.length; i++) waiters[i](bytes);
        }
        function onFileReadReady(path, contents, ok) {
            const waiters = root._readWaiters[path] || [];
            delete root._readWaiters[path];
            for (let i = 0; i < waiters.length; i++) {
                const w = waiters[i];
                if (ok) w.resolve(contents);
                else    w.reject(new Error("readFile failed: " + path));
            }
        }
        function onWallpaperDirChanged(path) {
            root.wallpaperDirChanged(path);
        }
    }
}
