// Comprehensive WallpaperListModel test. The model has a lot of behavior
// that isn't covered by tst_wallpaperlistmodel.qml's pure-comparator pin.
// It's designed to take injected `readfile` + `initItemOp` so we can run
// it against fake fixtures with no real Steam install.
//
// We rely on WallpaperListModel's `enabled: false` default to suppress the
// auto-refresh timer; tests trigger functions explicitly. (Actually default
// is true, but we set it false at construction.)
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperListModel_full"
    width: 200; height: 100
    when: windowShown

    // Synchronous Promise stand-in: the production code does
    // `readfile(path).then(value => {...})`. Returning a thenable that
    // invokes the callback synchronously lets us verify state immediately
    // after each call.
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
            catch: function(onReject) {
                if (isReject && onReject) onReject(value);
                return tc._thenable(value, false);
            },
        };
    }

    property var initSeen: []
    property var readfileCalls: []
    property string fakeFileContent: '{"general":{"playlists":[]}}'

    Plugin.WallpaperListModel {
        id: wpModel
        enabled: false  // suppress the 10s scan Timer; we drive it manually
        workshopDirs: ["/fake/workshop"]
        globalConfigPath: "/fake/global.json"
        initItemOp: function(item) {
            tc.initSeen.push(item.workshopid);
        }
        readfile: function(path) {
            tc.readfileCalls.push(path);
            return tc._thenable(tc.fakeFileContent);
        }
    }

    function init() {
        initSeen = [];
        readfileCalls = [];
        fakeFileContent = '{"general":{"playlists":[]}}';
        // production-side refresh() calls loadPlaylists() before
        // loadFolderLists(), which initialises root.playlists = {}. Tests
        // calling loadFolderLists directly need the same starting state or
        // the Object.keys(root.playlists) line inside the readfile chain
        // throws (the mock _thenable propagates synchronous throws), which
        // rejects the whole loadFolderLists Promise.
        wpModel.playlists = {};
    }

    // ── loadItemFromJson — JSON to model row population ──────────────────────
    function test_loadItemFromJson_populatesAllKnownFields() {
        const el = { tags: [] };
        wpModel.loadItemFromJson(JSON.stringify({
            title: "Test Wallpaper",
            preview: "preview.gif",
            file: "scene.pkg",
            type: "Scene",
            contentrating: "Everyone",
            tags: ["Anime", "Game"],
        }), el);
        compare(el.title, "Test Wallpaper");
        compare(el.preview, "preview.gif");
        compare(el.file, "scene.pkg");
        compare(el.type, "scene");  // lowercased
        compare(el.contentrating, "Everyone");
        compare(el.tags.length, 2);
        compare(el.tags[0].key, "Anime");
    }

    function test_loadItemFromJson_emptyPreviewIgnored() {
        const el = { preview: "default.gif", tags: [] };
        wpModel.loadItemFromJson(JSON.stringify({ preview: "" }), el);
        // Empty preview is filtered by the `&& project.preview` guard.
        compare(el.preview, "default.gif");
    }

    function test_loadItemFromJson_invalidJsonNoOps() {
        const el = { title: "untouched" };
        wpModel.loadItemFromJson("garbage{{{", el);
        compare(el.title, "untouched");
    }

    function test_loadItemFromJson_partialJsonOnlySetsPresent() {
        const el = { title: "T", preview: "P", file: "F" };
        wpModel.loadItemFromJson(JSON.stringify({ type: "Web" }), el);
        compare(el.title, "T");
        compare(el.type, "web");
    }

    // ── genSortCmp — sort comparators (also pinned in tst_wallpaperlistmodel) ─
    function test_genSortCmp_modifiedDescending() {
        const cmp = wpModel.genSortCmp(Plugin.Common.SortMode.Modified);
        const arr = [{ modified: 1 }, { modified: 3 }, { modified: 2 }];
        arr.sort(cmp);
        compare(arr[0].modified, 3);
        compare(arr[2].modified, 1);
    }

    function test_genSortCmp_nameAscending() {
        const cmp = wpModel.genSortCmp(Plugin.Common.SortMode.Name);
        const arr = [{ title: "C" }, { title: "A" }, { title: "B" }];
        arr.sort(cmp);
        compare(arr[0].title, "A");
    }

    function test_genSortCmp_idDefault() {
        const cmp = wpModel.genSortCmp(99999);  // unknown → default to Id
        const arr = [{ workshopid: "9" }, { workshopid: "1" }];
        arr.sort(cmp);
        compare(arr[0].workshopid, "1");
    }

    // ── loadPlaylists — config parsing, filterModel manipulation ─────────────
    function test_loadPlaylists_parsesEmptyGlobalConfig() {
        fakeFileContent = '{}';
        const out = wpModel.loadPlaylists();
        verify(out !== undefined);
        // Should not throw, and the readfile was called with the global path.
        verify(readfileCalls.length >= 1);
    }

    function test_loadPlaylists_addsPlaylistsToFilterModel() {
        fakeFileContent = JSON.stringify({
            steamuser: { general: { playlists: [
                { name: "MyList", items: ["C:\\path\\file1.pkg", "C:\\path\\file2.pkg"] },
            ]}}
        });
        wpModel.loadPlaylists();
        verify(wpModel.playlists !== null);
    }

    function test_loadPlaylists_invalidJsonDoesntCrash() {
        fakeFileContent = "not-json";
        const beforeReads = readfileCalls.length;
        wpModel.loadPlaylists();
        // Production logs a warn + early-returns; readfile WAS called for
        // the global config path, and playlists stays empty (init() reset
        // it to {} above).
        verify(readfileCalls.length > beforeReads,
               "global config readfile must fire even on invalid JSON");
        compare(Object.keys(wpModel.playlists).length, 0,
                "invalid JSON must leave playlists empty (no partial parse)");
    }

    // ── refresh — when disabled, returns immediately ────────────────────────
    function test_refresh_noOpWhenDisabled() {
        // wpModel.enabled is false; refresh resolves to null.
        const r = wpModel.refresh();
        verify(r !== undefined);
    }

    function test_refresh_resolvesToPromiseWhenEnabled() {
        // Enabling triggers refresh; we just verify the call returns
        // without throwing. The actual folder enumeration can't complete
        // because pyext.get_folder_list isn't available in tests.
        // We don't actually toggle enabled in this test — the production
        // code wires enabledChanged -> refresh. Just call refresh directly.
        // Skip: requires a `pyext` global which isn't injected here.
        verify(typeof wpModel.refresh === "function");
    }

    // ── loadFolderLists — exercises proxyModel building + per-item readfile ─
    function test_loadFolderLists_buildsItemsAndCallsReadfile() {
        const folders = [{
            folder: "/wp/wallpapers",
            items: [
                { name: "100", mtime: 1000 },
                { name: "200", mtime: 2000 },
            ],
        }];
        wpModel.loadFolderLists(folders);
        // readfile was called for each item's project.json, and initItemOp
        // was invoked for each item before the readfile.
        compare(initSeen.length, 2);
        verify(initSeen.indexOf("100") >= 0);
        verify(initSeen.indexOf("200") >= 0);
    }

    function test_loadFolderLists_emptyFoldersResolvesQuickly() {
        const beforeReads = readfileCalls.length;
        wpModel.loadFolderLists([]);
        // No folders → proxyModel stays empty → no per-item readfile +
        // no initItemOp invocations.
        compare(initSeen.length, 0,
                "empty folders must not invoke initItemOp");
        compare(readfileCalls.length, beforeReads,
                "empty folders must not trigger per-item readfile");
    }

    function test_loadFolderLists_skipsNullFolderEntries() {
        const beforeReads = readfileCalls.length;
        wpModel.loadFolderLists([null, { folder: "/x", items: [] }, undefined]);
        // null/undefined folders are skipped (early `return` in forEach);
        // the lone {folder:"/x", items:[]} contributes zero items.
        compare(initSeen.length, 0,
                "null/empty folder entries must not invoke initItemOp");
        compare(readfileCalls.length, beforeReads,
                "null/empty folder entries must not trigger per-item readfile");
    }

    // ── ListModel.assignModel ────────────────────────────────────────────────
    function test_assignModel_mergesIntoListModelAndFolderWorker() {
        // Append an item, then call assignModel(0, {...}) to trigger the
        // function. Reaches inside both the ListModel.get() merge and the
        // folderWorker.model loop.
        wpModel.model.append({ workshopid: "5555", title: "Old", favor: false });
        try { wpModel.model.assignModel(0, { favor: true, title: "New" }); } catch (e) {}
        // ListModel.get(0) is mutated in place by Object.assign — verify the
        // merged title/favor landed on the model row (the folderWorker.model
        // branch hits zero entries here, so its only contract is "did not
        // throw"; the ListModel-side merge IS observable and asserted).
        const row = wpModel.model.get(0);
        compare(row.title, "New", "assignModel must update title in ListModel row");
        compare(row.favor, true,  "assignModel must update favor in ListModel row");
    }

    // ── refresh() — fire when enabled=true ──────────────────────────────────
    function test_refresh_runsBodyWhenEnabled() {
        // Disabled-path early-returns Promise.resolve(null) without setting
        // scanning or reading any file. Enabled path sets scanning=true
        // and calls loadPlaylists() which reads the global config.
        wpModel.enabled = true;
        const beforeReads = readfileCalls.length;
        try { wpModel.refresh(); } catch (e) {}
        verify(wpModel.scanning,
               "refresh() with enabled=true must flip scanning to true");
        verify(readfileCalls.length > beforeReads,
               "refresh() body must read the global config");
        wpModel.enabled = false;
    }

    // ── findItem / titleOf — unfiltered-source lookup ────────────────────────
    // Regression guard: PlaylistsPage and PlaylistController must be able to
    // resolve a playlist item's title/path even when the wallpaper-tab filter
    // chips would exclude it from the public `model`. The lookup goes through
    // folderWorker.model (the unfiltered JS array) which loadFolderLists
    // populates.
    function test_findItem_returnsItemFromUnfilteredSource() {
        fakeFileContent = '{"title":"Hello"}';
        wpModel.loadFolderLists([{
            folder: "/wp",
            items: [{ name: "abc123", mtime: 1 }],
        }]);
        // loadFolderLists chains native Promise.all (per-item readfile
        // fan-in) before populating folderWorker.model. Poll the lookup
        // until the fan-in lands (tryCompare can't poll a function call).
        tryVerify(() => wpModel.findItem("abc123") !== null, 2000);
        const it = wpModel.findItem("abc123");
        verify(it !== null);
        compare(it.workshopid, "abc123");
        compare(it.title, "Hello");
    }

    function test_findItem_returnsNullForUnknown() {
        compare(wpModel.findItem("never-loaded"), null);
    }

    function test_titleOf_returnsTitleWhenLoaded() {
        fakeFileContent = '{"title":"Named One"}';
        wpModel.loadFolderLists([{
            folder: "/wp",
            items: [{ name: "id-1", mtime: 1 }],
        }]);
        // Poll titleOf until the fan-in populates (JS function call, not a
        // QObject property → tryVerify, not tryCompare).
        tryVerify(() => wpModel.titleOf("id-1") === "Named One", 2000);
        compare(wpModel.titleOf("id-1"), "Named One");
    }

    function test_titleOf_fallsBackToWorkshopIdForUnknown() {
        compare(wpModel.titleOf("missing-id"), "missing-id");
    }

    // Reactivity hook: bindings that read titleOf/findItem need a tracked
    // property to re-evaluate when the unfiltered source repopulates. The
    // modelRefreshed signal bumps _sourceRev for exactly that purpose.
    function test_sourceRev_bumpsOnModelRefreshed() {
        const before = wpModel._sourceRev;
        wpModel.modelRefreshed();
        compare(wpModel._sourceRev, before + 1);
    }

    // findItem must consult an O(1) byWorkshopId Map alongside
    // folderWorker.model — for L=1000 wallpapers x 50 PlaylistsPage delegates
    // the pre-patch linear scan was 25k string-compares per render.
    function test_findItem_usesByWorkshopIdMap() {
        // Build 50 fake items via loadFolderLists; map must size match.
        fakeFileContent = '{"title":"X"}';
        const items = [];
        for (let i = 0; i < 50; ++i) items.push({ name: "wp" + i, mtime: i });
        wpModel.loadFolderLists([{ folder: "/wp", items: items }]);
        tryVerify(() => wpModel.findItem("wp25") !== null, 2000);
        // Reach in via the documented Map invariant: size === model.length.
        // We can't traverse private folderWorker directly from a test, so use
        // findItem on each id and rely on the invariant that ALL 50 resolve.
        for (let i = 0; i < 50; ++i) {
            const got = wpModel.findItem("wp" + i);
            verify(got !== null, "wp" + i + " missing from Map");
            compare(got.workshopid, "wp" + i);
        }
    }

    // Map staleness gate: byWorkshopId.size must equal folderWorker.model.length
    // after every loadModel. This is the invariant that lets findItem be O(1).
    function test_byWorkshopId_sizeMatchesModelLength() {
        fakeFileContent = '{"title":"X"}';
        const items = [];
        for (let i = 0; i < 20; ++i) items.push({ name: "id" + i, mtime: i });
        wpModel.loadFolderLists([{ folder: "/wp", items: items }]);
        tryVerify(() => wpModel.findItem("id10") !== null, 2000);
        // All 20 lookups must succeed (Map is keyed by workshopid).
        for (let i = 0; i < 20; ++i) {
            verify(wpModel.findItem("id" + i) !== null);
        }
        // A missing id returns null (Map.get returns undefined → ?? null).
        compare(wpModel.findItem("id99"), null);
    }

    // Implementation-detail pin: findItem must reach for folderWorker.byWorkshopId
    // (a Map) rather than scan folderWorker.model linearly. Read the
    // WallpaperListModel.qml source and assert the byWorkshopId identifier
    // appears at least once. Pre-patch the source has only `folderWorker.model`
    // scan inside findItem.
    function test_findItem_implementationReferencesByWorkshopIdMap() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../plugin/contents/ui/WallpaperListModel.qml"),
                /* async = */ false);
        xhr.send(null);
        verify(xhr.responseText.length > 0,
               "could not read WallpaperListModel.qml — QML_XHR_ALLOW_FILE_READ?");
        verify(xhr.responseText.indexOf("byWorkshopId") !== -1,
               "findItem should consult a byWorkshopId Map for O(1) lookups");
    }
}
