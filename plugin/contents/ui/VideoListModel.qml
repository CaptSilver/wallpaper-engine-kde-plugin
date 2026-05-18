// Async-loading list of plain video files conforming to wpitem_template so
// the shared WallpaperGrid can render them. Independent from
// WallpaperListModel; the only convergence point is the grid component.
import QtQuick

Item {
    id: root
    property string folderPath: ""
    property string cachePath: ""
    property var pyext: null

    readonly property ListModel model: ListModel {}

    // Generation counter — refresh() bumps it; only the latest scan's
    // .then commits to the model. Prevents double-refresh races between
    // the onFolderPathChanged auto-trigger and explicit caller refresh().
    property int _refreshGen: 0

    // True while a folder scan is in progress. UI binds Rescan buttons +
    // BusyIndicators to this so the user gets feedback that a 5s-on-a-big-
    // folder operation is actually working.
    property bool scanning: false

    onFolderPathChanged: refresh()

    // FNV-1a 32-bit, hex-padded to 16 chars. Stable per absolute path —
    // the same path always yields the same id (used as workshopid suffix
    // and as the on-disk thumbnail cache key).
    function _hash16(s) {
        let h = 0x811c9dc5 >>> 0;
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = (h * 0x01000193) >>> 0;
        }
        return ("0000000000000000" + h.toString(16)).slice(-16);
    }

    // Strip "file://" if cachePath is a URL (PluginInfo gives a QUrl).
    function _localCacheRoot() {
        if (! cachePath) return "";
        return cachePath.indexOf("file://") === 0
            ? cachePath.substring(7)
            : cachePath;
    }

    function _thumbPathFor(workshopid) {
        const root_ = _localCacheRoot();
        if (! root_) return "";
        return root_ + "/video-thumbs/" + workshopid.slice(6) + ".jpg";
    }

    function refresh() {
        const gen = ++root._refreshGen;
        root.scanning = true;
        model.clear();
        if (! folderPath || ! pyext) {
            root.scanning = false;
            return Promise.resolve();
        }
        return pyext.scan_video_folder(folderPath).then((list) => {
            // Stale scan — a newer refresh() superseded this one.
            if (gen !== root._refreshGen) return;
            model.clear();
            for (let i = 0; i < list.length; i++) {
                const f = list[i];
                const id = "video:" + _hash16(f.path);
                const dotIdx = f.name.lastIndexOf(".");
                const title  = dotIdx > 0 ? f.name.slice(0, dotIdx) : f.name;
                const dirEnd = f.path.lastIndexOf("/");
                const dir    = dirEnd >= 0 ? f.path.slice(0, dirEnd) : f.path;
                model.append({
                    workshopid: id,
                    path: dir,
                    file: f.name,
                    type: "video",
                    title: title,
                    // Empty until thumbnail is generated; the Image binds to
                    // `preview` so it'll auto-reload when we setProperty later.
                    preview: "",
                    _videoFullPath: f.path,
                    contentrating: "Everyone",
                    tags: [],
                    favor: false,
                    playlists: [],
                    loaded: true,
                    modified: f.mtime,
                });
            }
            // Thumbnail generation continues async, but the list is
            // committed — flip scanning back off so the UI re-enables.
            root.scanning = false;
            _kickThumbnails(gen);
        }).catch((e) => {
            root.scanning = false;
            console.warn("VideoListModel: scan failed", e);
        });
    }

    // Fire generate_thumbnail for every item lacking a preview. FileHelper
    // short-circuits when the cache file already exists, so subsequent scans
    // resolve thumbnails near-instantly.
    function _kickThumbnails(gen) {
        if (! pyext || ! _localCacheRoot()) return;
        for (let i = 0; i < model.count; i++) {
            const it = model.get(i);
            const out = _thumbPathFor(it.workshopid);
            const idx = i;
            const wid = it.workshopid;
            const fullPath = it._videoFullPath;
            pyext.generate_thumbnail(fullPath, out, 1.0).then((p) => {
                // Stale scan — model may have been cleared / repopulated.
                if (gen !== root._refreshGen) return;
                if (idx >= model.count) return;
                if (model.get(idx).workshopid !== wid) return;
                model.setProperty(idx, "preview", p);
            }).catch((e) => {
                console.warn("VideoListModel: thumb gen failed for", fullPath, e);
            });
        }
    }
}
