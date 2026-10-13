// Lifetime of the list models' async chains. A model can be destroyed while
// its playlist read / library scan / thumbnail queue is still in flight (the
// wallpaper KCM builds a page, discards it and builds another), and the
// continuations then run in a torn-down context: `root` reads as null there,
// so any guard has to live on a token the closure captured, and the shared
// Common.filterModel singleton must be left alone.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "ListModelTeardown"
    width: 200; height: 100
    when: windowShown

    property int folderListCalls: 0
    property var pendingReads: []
    property var readPaths: []
    property var thumbCalls: []
    property var pendingThumbs: []
    property var videoFiles: []

    readonly property string playlistsJson:
        '{"steamuser":{"general":{"playlists":[{"name":"stale","items":[]}]}}}'

    QtObject {
        id: stubPyext
        function get_folder_list(path, opts) {
            tc.folderListCalls += 1;
            return Promise.resolve({ folder: path, items: [] });
        }
        function unwatch_all_wallpaper_dirs() {}
        function watch_wallpaper_dir(path) {}
    }

    QtObject {
        id: stubVideoPyext
        function scan_video_folder(path) { return Promise.resolve(tc.videoFiles); }
        function generate_thumbnail(videoPath, outPath, at) {
            tc.thumbCalls.push(videoPath);
            return new Promise(res => tc.pendingThumbs.push(() => res(outPath)));
        }
        function video_thumb_dir(root) { return root + "/video-thumbs"; }
    }

    Component {
        id: wpComp
        Plugin.WallpaperListModel {
            pyext: stubPyext
            globalConfigPath: "/wek-none/cfg.json"
            workshopDirs: ["/wek-none"]
        }
    }
    Component {
        id: videoComp
        Plugin.VideoListModel {
            pyext: stubVideoPyext
            cachePath: "/wek-none/cache"
        }
    }

    function _playlistKeys() {
        const fm = Plugin.Common.filterModel;
        const out = [];
        for (let i = 0; i < fm.count; i++)
            if (fm.get(i).type === "playlist") out.push(fm.get(i).key);
        return out;
    }

    function _clearPlaylistEntries() {
        const fm = Plugin.Common.filterModel;
        for (let i = fm.count - 1; i >= 0; i--)
            if (fm.get(i).type === "playlist") fm.remove(i);
    }

    // readfile that parks every request; the test settles them by hand.
    function _parkedRead(path) {
        return new Promise(res => tc.pendingReads.push(res));
    }

    function _wpModel(props) {
        return wpComp.createObject(tc, Object.assign({
            loadEnabled: true,
            readfile: tc._parkedRead,
        }, props || {}));
    }

    function _videoFiles(prefix, n) {
        const out = [];
        for (let i = 0; i < n; i++)
            out.push({ path: "/v/" + prefix + i + ".mp4", name: prefix + i + ".mp4",
                       mtime: i, size: 1 });
        return out;
    }

    function init() {
        failOnWarning(/TypeError|ReferenceError/);
        folderListCalls = 0;
        pendingReads = [];
        thumbCalls = [];
        pendingThumbs = [];
        _clearPlaylistEntries();
    }

    function cleanup() {
        _clearPlaylistEntries();
        // A leaked lock would wedge every later test (and the next KCM page).
        Plugin.Common.filterModel.lock.locked = false;
        Plugin.Common.filterModel.lock.lock_resolvers = [];
    }

    // Control: the fixture really drives loadPlaylists, so the destroyed
    // variant below going quiet means the guard worked, not that the fixture
    // was dead.
    function test_liveModel_replacesPlaylists() {
        Plugin.Common.filterModel.append(
            { type: "playlist", key: "keepme", text: "keepme", def: 0 });
        const m = _wpModel();
        verify(m);
        compare(pendingReads.length, 1);
        pendingReads[0](playlistsJson);
        tryVerify(() => _playlistKeys().indexOf("stale") >= 0);
        compare(_playlistKeys().indexOf("keepme"), -1);
        tryCompare(tc, "folderListCalls", 1);
        compare(Plugin.Common.filterModel.lock.locked, false);
        m.destroy();
    }

    function test_destroyedModel_leavesSharedPlaylistsAlone() {
        Plugin.Common.filterModel.append(
            { type: "playlist", key: "keepme", text: "keepme", def: 0 });
        const m = _wpModel();
        verify(m);
        compare(pendingReads.length, 1);
        m.destroy();
        wait(50);
        pendingReads[0](playlistsJson);
        wait(100);
        verify(_playlistKeys().indexOf("keepme") >= 0,
               "a dead model must not strip the shared playlist entries");
        compare(_playlistKeys().indexOf("stale"), -1);
        compare(folderListCalls, 0);
        compare(Plugin.Common.filterModel.lock.locked, false);
    }

    // A superseded refresh must stop before touching the shared singleton
    // too, otherwise its playlists land after the newer scan's.
    function test_supersededRefresh_isIgnored() {
        const m = _wpModel();
        verify(m);
        compare(pendingReads.length, 1);
        m.refresh();
        compare(pendingReads.length, 2);
        pendingReads[0](playlistsJson);
        wait(100);
        compare(_playlistKeys().indexOf("stale"), -1);
        compare(folderListCalls, 0);
        pendingReads[1](playlistsJson);
        tryCompare(tc, "folderListCalls", 1);
        verify(_playlistKeys().indexOf("stale") >= 0);
        m.destroy();
    }

    function test_pathChangeWhileEnabled_rescansOnce() {
        const m = _wpModel({ readfile: () => Promise.resolve("{}") });
        verify(m);
        tryCompare(tc, "folderListCalls", 1);
        wait(50);
        m.workshopDirs = ["/wek-other"];
        wait(150);
        compare(folderListCalls, 2);
        m.destroy();
    }

    // Mirrors config.qml: one library property feeds workshopDirs,
    // globalConfigPath and loadEnabled through bindings, in that order.
    Component {
        id: boundComp
        Item {
            property string lib: ""
            property alias model: bm
            Plugin.WallpaperListModel {
                id: bm
                pyext: stubPyext
                workshopDirs: Plugin.Common.getProjectDirs(parent.lib)
                globalConfigPath: Plugin.Common.getGlobalConfigPath(parent.lib)
                loadEnabled: Boolean(parent.lib)
                readfile: (p) => { tc.readPaths.push(p); return Promise.resolve("{}"); }
            }
        }
    }

    function test_emptyToSet_rescansOnce() {
        const h = boundComp.createObject(tc);
        verify(h);
        wait(50);
        folderListCalls = 0;
        readPaths = [];
        h.lib = "/wek-libA";
        wait(150);
        // One scan walks the three project dirs and reads the config once.
        compare(folderListCalls, 3);
        const want = Plugin.Common.urlNative(Plugin.Common.getGlobalConfigPath("/wek-libA"));
        compare(readPaths.length, 1);
        compare(readPaths[0], want,
                "the playlists must come from the new library's config.json");
        h.destroy();
    }

    function test_supersededVideoScan_stopsOldThumbnailQueue() {
        videoFiles = _videoFiles("o", 6);
        const m = videoComp.createObject(tc, { folderPath: "/v" });
        verify(m);
        tryVerify(() => thumbCalls.length === 4);
        videoFiles = _videoFiles("n", 6);
        m.refresh();
        tryVerify(() => thumbCalls.length === 8);
        // Settle every in-flight thumbnail; the old queue still holds o4, o5.
        const settle = pendingThumbs.slice();
        pendingThumbs = [];
        settle.forEach(f => f());
        wait(100);
        verify(thumbCalls.indexOf("/v/o4.mp4") < 0,
               "a superseded scan must not keep draining its thumbnail queue");
        verify(thumbCalls.indexOf("/v/o5.mp4") < 0);
        m.destroy();
    }

    function test_destroyedVideoModel_stopsThumbnailQueue() {
        videoFiles = _videoFiles("o", 6);
        const m = videoComp.createObject(tc, { folderPath: "/v" });
        verify(m);
        tryVerify(() => thumbCalls.length === 4);
        m.destroy();
        wait(50);
        pendingThumbs.forEach(f => f());
        wait(100);
        compare(thumbCalls.length, 4);
    }
}
