// Watcher integration test for WallpaperListModel: a QFileSystemWatcher event
// (delivered as pyext.wallpaperDirChanged) must trigger a debounced refresh()
// 500 ms later. The Connections / Timer wiring lives inside WallpaperListModel;
// this test injects a fake pyext stub + spies on refresh() invocations.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperListModelWatchTest"
    width: 200; height: 100
    when: windowShown

    // Mock pyext: records watch / unwatch + emits a wallpaperDirChanged
    // signal on demand so tests can drive the debounce path explicitly.
    property int watchCalls: 0
    property int unwatchAllCalls: 0
    property var lastWatchedPath: ""
    property int refreshCalls: 0

    // Synchronous Promise stand-in (mirrors the other WallpaperListModel
    // tests). The injected readfile resolves synchronously via this thenable
    // so loadFolderLists' fan-in completes in place.
    function _thenable(value, isReject) {
        return {
            then: function(onResolve, onReject) {
                if (isReject) {
                    if (onReject) {
                        const r = onReject(value);
                        return r && r.then ? r : tc._thenable(undefined);
                    }
                    return tc._thenable(value, true);
                }
                if (onResolve) {
                    const r = onResolve(value);
                    return r && r.then ? r : tc._thenable(r);
                }
                return tc._thenable(value);
            },
            catch: function(onReject) { return tc._thenable(value, false); },
        };
    }

    QtObject {
        id: pyext

        signal wallpaperDirChanged(string path)

        function watch_wallpaper_dir(path) {
            tc.watchCalls += 1;
            tc.lastWatchedPath = path;
        }
        function unwatch_all_wallpaper_dirs() {
            tc.unwatchAllCalls += 1;
        }
        function get_folder_list(dir, opts) {
            return tc._thenable({ folder: dir, items: [] });
        }
    }

    Plugin.WallpaperListModel {
        id: wpModel
        enabled: true
        workshopDirs: ["/fake/workshop"]
        globalConfigPath: "/fake/global.json"
        initItemOp: function(item) {}
        readfile: function(path) { return tc._thenable('{"general":{"playlists":[]}}'); }
        Component.onCompleted: { wpModel.playlists = {}; }
    }

    SignalSpy {
        id: refreshSpy
        target: wpModel
        signalName: "modelRefreshed"
    }

    function init() {
        watchCalls = 0;
        unwatchAllCalls = 0;
        lastWatchedPath = "";
        refreshSpy.clear();
    }

    // The Component.onCompleted path calls _attachWatchers() which in turn
    // unwatches then re-adds one entry per workshopDirs element. Since
    // attachment happens at construction (before init() runs), we observe
    // post-construction state via a flag the production code sets.
    function test_attachWatchers_canBeInvokedDirectly() {
        // Drive _attachWatchers explicitly. It must call unwatch_all + one
        // watch per workshop dir (here: just one entry).
        wpModel._attachWatchers();
        verify(unwatchAllCalls >= 1, "_attachWatchers must call unwatch_all first");
        verify(watchCalls >= 1, "_attachWatchers must call watch_wallpaper_dir");
        // Common.urlNative strips file:// — our raw path stays as-is.
        compare(lastWatchedPath, "/fake/workshop");
    }

    function test_workshopDirsChange_reattachesWatchers() {
        // Reset counters AFTER any onCompleted-time attach.
        watchCalls = 0;
        unwatchAllCalls = 0;
        wpModel.workshopDirs = ["/another/library", "/second/library"];
        // _attachWatchers fires from onWorkshopDirsChanged. Synchronous in QML.
        verify(unwatchAllCalls >= 1,
               "workshopDirs change must trigger unwatch_all_wallpaper_dirs");
        compare(watchCalls, 2,
                "watch_wallpaper_dir must fire once per workshopDirs entry");
    }

    function test_wallpaperDirChanged_debounces500msThenRefreshes() {
        // Clear the spy AFTER any onCompleted-time refresh, then drive one
        // watcher event and assert refresh() fires after the debounce window.
        refreshSpy.clear();
        // Fire the watcher signal — debounce Timer starts at 500 ms.
        pyext.wallpaperDirChanged("/fake/workshop");
        // Immediately after, refresh() has NOT yet been called (debounced).
        compare(refreshSpy.count, 0,
                "refresh() must NOT fire synchronously on watcher event");
        // Within 2000 ms (500 ms debounce + scan time + buffer), refresh
        // must fire (modelRefreshed signals it ran).
        tryVerify(() => refreshSpy.count > 0, 2000);
    }

    function test_multipleEvents_coalesceIntoOneRefresh() {
        refreshSpy.clear();
        // Fire 3 events back-to-back (Steam's atomic-rename pattern).
        pyext.wallpaperDirChanged("/fake/workshop");
        pyext.wallpaperDirChanged("/fake/workshop");
        pyext.wallpaperDirChanged("/fake/workshop");
        // 500 ms debounce coalesces.
        tryVerify(() => refreshSpy.count > 0, 2000);
        // Wait the full debounce window to confirm no second refresh fires.
        wait(800);
        compare(refreshSpy.count, 1,
                "3 rapid watcher events must coalesce into exactly 1 refresh");
    }
}
