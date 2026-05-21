import QtQuick 2.0
import com.github.captsilver.wallpaperEngineKde 1.2

// FileHelper wrapper with Promise-like API for backwards compatibility
Item {
    id: root

    // Always ready (no Python startup delay)
    readonly property bool ok: true
    readonly property string log: ""
    readonly property string version: "native"

    // Internal C++ FileHelper instance
    FileHelper {
        id: fileHelper
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
        const data = fileHelper.readFile(path);
        // Return as string (QML handles QByteArray to string conversion)
        return _makePromise(data);
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

    // Pending thumbnail requests keyed by videoPath. Each entry is an array of
    // {resolve, reject, outPath} callbacks waiting on the next thumbnailReady
    // signal matching that videoPath.
    property var _thumbWaiters: ({})
    // Pending getDirSize requests keyed by absolute path. Each entry is an array
    // of resolve callbacks waiting on the next dirSizeReady for that path.
    property var _dirSizeWaiters: ({})

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
    }
}
