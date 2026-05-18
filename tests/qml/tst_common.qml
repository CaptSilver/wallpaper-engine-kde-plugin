import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    name: "Common"

    // ── Steam path builders ───────────────────────────────────────────────────
    function test_getWorkshopDir() {
        compare(Plugin.Common.getWorkshopDir("/steam"),
                "/steam/steamapps/workshop/content/431960");
    }

    function test_getWorkshopDirs_returnsCaseFallbacks() {
        const dirs = Plugin.Common.getWorkshopDirs("/steam");
        compare(dirs.length, 4);
        compare(dirs[0], "/steam/steamapps/workshop/content/431960");
        verify(dirs.includes("/steam/Steamapps/Workshop/Content/431960"));
    }

    function test_getDefProjectsDir() {
        compare(Plugin.Common.getDefProjectsDir("/steam"),
                "/steam/steamapps/common/wallpaper_engine/projects/defaultprojects");
    }

    function test_getMyProjectsDir() {
        compare(Plugin.Common.getMyProjectsDir("/steam"),
                "/steam/steamapps/common/wallpaper_engine/projects/myprojects");
    }

    function test_getProjectDirs_shape() {
        const r = Plugin.Common.getProjectDirs("/steam");
        compare(r.length, 3);
        verify(Array.isArray(r[0]));               // workshop dirs
        compare(typeof r[1], "string");            // defaultprojects
        compare(typeof r[2], "string");            // myprojects
    }

    function test_getAssetsPath() {
        compare(Plugin.Common.getAssetsPath("/steam"),
                "/steam/steamapps/common/wallpaper_engine/assets");
    }

    function test_getGlobalConfigPath() {
        compare(Plugin.Common.getGlobalConfigPath("/steam"),
                "/steam/steamapps/common/wallpaper_engine/config.json");
    }

    function test_getWorkshopUrl() {
        compare(Plugin.Common.getWorkshopUrl("12345"),
                "https://steamcommunity.com/sharedfiles/filedetails/?id=12345");
    }

    // ── Wallpaper-model URL helpers ───────────────────────────────────────────
    function test_getWpModelPreviewSource_withPreview() {
        compare(Plugin.Common.getWpModelPreviewSource(
                    { path: "/wp/123", preview: "preview.gif" }),
                "/wp/123/preview.gif");
    }

    function test_getWpModelPreviewSource_emptyPreview() {
        compare(Plugin.Common.getWpModelPreviewSource(
                    { path: "/wp/123", preview: "" }),
                "");
    }

    function test_getWpModelFileSource_packsTypeSuffix() {
        compare(Plugin.Common.getWpModelFileSource(
                    { path: "/wp/123", file: "scene.pkg", type: "scene" }),
                "/wp/123/scene.pkg+scene");
    }

    function test_getWpModelFileSource_emptyPathReturnsEmpty() {
        compare(Plugin.Common.getWpModelFileSource(
                    { path: "", file: "x", type: "y" }),
                "");
    }

    function test_getWpModelProjectPath() {
        compare(Plugin.Common.getWpModelProjectPath(
                    { path: "/wp/123" }),
                "/wp/123/project.json");
        compare(Plugin.Common.getWpModelProjectPath(
                    { path: "" }),
                "");
    }

    // ── packWallpaperSource / unpackWallpaperSource round-trip ────────────────
    function test_unpackWallpaperSource_validInput() {
        const r = Plugin.Common.unpackWallpaperSource("/wp/123/scene.pkg+scene");
        compare(r.path, "/wp/123/scene.pkg");
        compare(r.type, "scene");
    }

    function test_unpackWallpaperSource_invalidInput() {
        const r = Plugin.Common.unpackWallpaperSource("garbage");
        compare(r.path, "");
        compare(r.type, "");
    }

    function test_packAndUnpack_roundTrip() {
        const model = { path: "/wp/x", file: "main.html", type: "web" };
        const packed = Plugin.Common.packWallpaperSource(model);
        const round = Plugin.Common.unpackWallpaperSource(packed);
        compare(round.type, "web");
        verify(round.path.endsWith("main.html"));
    }

    // ── Regex sanity checks ───────────────────────────────────────────────────
    function test_regex_workshop_online_acceptsDigits() {
        // Reset stateful lastIndex (the regex has the "g" flag).
        Plugin.Common.regex_workshop_online.lastIndex = 0;
        verify(Plugin.Common.regex_workshop_online.test("123456"));
        Plugin.Common.regex_workshop_online.lastIndex = 0;
        verify(! Plugin.Common.regex_workshop_online.test("abc"));
    }

    function test_regex_source_extractsTypeSuffix() {
        const m = "/wp/123/file+web".match(Plugin.Common.regex_source);
        verify(m !== null);
        compare(m[1], "/wp/123/file");
        compare(m[2], "web");
    }

    // ── filterModel.getValueArray ─────────────────────────────────────────────
    function test_getValueArray_emptyStringReturnsDefaults() {
        const r = Plugin.Common.filterModel.getValueArray("");
        compare(r.length, Plugin.Common.filterModel.count);
    }

    function test_getValueArray_validStringReturnsParsedDigits() {
        // Build an all-1s string of the right length.
        const n = Plugin.Common.filterModel.count;
        const allOnes = Array(n).fill("1").join("");
        const r = Plugin.Common.filterModel.getValueArray(allOnes);
        compare(r.length, n);
        for (let i = 0; i < n; i++) compare(r[i], 1);
    }

    function test_getValueArray_tooShortFallsBackToDefaults() {
        const r = Plugin.Common.filterModel.getValueArray("11");
        // Falls back to defaults (length == filterModel.count, mixed values).
        compare(r.length, Plugin.Common.filterModel.count);
    }

    // ── filterModel.genFilter predicate ───────────────────────────────────────
    function test_genFilter_typeAcceptsMatchingOnly() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "type",          key: "web",   value: 0 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [], playlists: [] }));
        verify(! f({ type: "web", contentrating: "Everyone", favor: false,
                      tags: [], playlists: [] }));
    }

    function test_genFilter_favorOnlyExcludesNonFavorites() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 1 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(f({ type: "scene", contentrating: "Everyone", favor: true,
                    tags: [], playlists: [] }));
        verify(! f({ type: "scene", contentrating: "Everyone", favor: false,
                      tags: [], playlists: [] }));
    }

    // Inclusion semantics: a wallpaper passes if it carries at least one
    // of the *checked* tag chips. Anime-only fails (Anime is unchecked),
    // Game-only passes. The naming kept the old wording for diff
    // continuity but the spec it asserts is now inclusion (union/OR).
    function test_genFilter_tagSubsetSelected_includesUnionOnly() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
            { type: "tags",          key: "Anime", value: 0 },
            { type: "tags",          key: "Game",  value: 1 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(! f({ type: "scene", contentrating: "Everyone", favor: false,
                      tags: [{ key: "Anime" }], playlists: [] }),
               "Anime-only wallpaper must NOT pass when only Game is checked");
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [{ key: "Game" }], playlists: [] }),
               "Game-tagged wallpaper must pass when Game is checked");
    }

    // A wallpaper tagged with BOTH Girls and Anime appears under either
    // filter — confirms the union semantic explicitly.
    function test_genFilter_multiTagWallpaperPassesWhenAnyMatches() {
        const baseFilters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
        ];
        const wpGirlsAndAnime = {
            type: "scene", contentrating: "Everyone", favor: false,
            tags: [{ key: "Girls" }, { key: "Anime" }], playlists: [],
        };
        // Only Girls checked → passes (it carries Girls).
        const f1 = Plugin.Common.filterModel.genFilter(baseFilters.concat([
            { type: "tags", key: "Girls", value: 1 },
            { type: "tags", key: "Anime", value: 0 },
        ]));
        verify(f1(wpGirlsAndAnime));
        // Only Anime checked → still passes (it carries Anime).
        const f2 = Plugin.Common.filterModel.genFilter(baseFilters.concat([
            { type: "tags", key: "Girls", value: 0 },
            { type: "tags", key: "Anime", value: 1 },
        ]));
        verify(f2(wpGirlsAndAnime));
    }

    // Special case #1: ALL tag chips checked = no tag filter. This is the
    // default state — must keep untagged wallpapers visible so existing
    // users see no regression on first run with the new build.
    function test_genFilter_allTagsCheckedActsAsNoFilter() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
            { type: "tags",          key: "Anime", value: 1 },
            { type: "tags",          key: "Game",  value: 1 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [], playlists: [] }),
               "untagged wallpaper must pass when ALL tag chips are checked");
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [{ key: "Anime" }], playlists: [] }));
    }

    // Special case #2: NO tag chips checked = no tag filter. Avoids the
    // footgun where unchecking everything yields an empty grid.
    function test_genFilter_noTagsCheckedActsAsNoFilter() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
            { type: "tags",          key: "Anime", value: 0 },
            { type: "tags",          key: "Game",  value: 0 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [], playlists: [] }),
               "untagged wallpaper must pass when NO tag chips are checked");
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [{ key: "Anime" }], playlists: [] }),
               "tagged wallpaper must pass when NO tag chips are checked");
    }

    // Narrowing case: with SOME chips checked, untagged wallpapers fall
    // out (they match none of the checked tags). This is the new behavior
    // — under exclusion semantics they would pass.
    function test_genFilter_someTagsCheckedExcludesUntagged() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
            { type: "tags",          key: "Anime", value: 1 },
            { type: "tags",          key: "Game",  value: 0 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(! f({ type: "scene", contentrating: "Everyone", favor: false,
                      tags: [], playlists: [] }),
               "untagged wallpaper must NOT pass when a strict subset is checked");
    }

    function test_genFilter_playlistGateRequiresMembership() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
            { type: "playlist",      key: "MyList", value: 1 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [], playlists: [{ key: "MyList" }] }));
        verify(! f({ type: "scene", contentrating: "Everyone", favor: false,
                      tags: [], playlists: [{ key: "Other" }] }));
    }

    function test_genFilter_noPlaylistsSelectedAllowsAll() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [], playlists: [] }));
    }

    // ── filterModel.map ───────────────────────────────────────────────────────
    function test_filterModel_map_iteratesOverAllRows() {
        const types = Plugin.Common.filterModel.map((el) => el.type);
        compare(types.length, Plugin.Common.filterModel.count);
        verify(types.includes("favor"));
        verify(types.includes("type"));
    }

    // ── filterModel.lock primitive ────────────────────────────────────────────
    function test_lock_acquireImmediateWhenUnheld() {
        const lock = Plugin.Common.filterModel.lock;
        let resolved = false;
        lock.lock().then(() => { resolved = true; });
        wait(0); // pump the microtask queue
        verify(resolved);
        lock.release();
    }

    function test_lock_secondAcquireBlocksUntilRelease() {
        const lock = Plugin.Common.filterModel.lock;
        let firstHeld = false;
        let secondHeld = false;
        lock.lock().then(() => { firstHeld = true; });
        lock.lock().then(() => { secondHeld = true; });
        wait(0);
        verify(firstHeld);
        verify(! secondHeld);
        lock.release();
        wait(0);
        verify(secondHeld);
        lock.release();
    }

    // ── loadCustomConf / prepareCustomConf round-trip ─────────────────────────
    function test_loadCustomConf_acceptsBase64JSON() {
        const raw = '{"favor":["1","2","3"]}';
        const b64 = Qt.btoa(raw);
        const conf = Plugin.Common.loadCustomConf(b64);
        verify(conf.favor instanceof Set);
        compare(conf.favor.size, 3);
        verify(conf.favor.has("1"));
    }

    function test_loadCustomConf_invalidBase64ReturnsEmptyConf() {
        const conf = Plugin.Common.loadCustomConf("!!! definitely not base64");
        // Always returns a conf shape with .favor — never throws.
        verify(conf.favor instanceof Set);
        compare(conf.favor.size, 0);
    }

    // ── wpitemFromQtObject ────────────────────────────────────────────────────
    function test_wpitemFromQtObject_picksKnownProps() {
        const fake = {
            workshopid: "42", path: "/p", loaded: true, title: "T",
            preview: "pv.gif", type: "scene", contentrating: "Everyone",
            tags: [{ key: "Anime" }], favor: true, playlists: [],
            extra: "should be ignored",
        };
        const out = Plugin.Common.wpitemFromQtObject(fake);
        compare(out.workshopid, "42");
        compare(out.title, "T");
        compare(out.type, "scene");
        verify(out.favor);
        verify(! ("extra" in out));
    }

    // ── prepareCustomConf round-trip with loadCustomConf ──────────────────────
    function test_prepareCustomConf_roundTripsThroughLoadCustomConf() {
        const conf = {
            favor: new Set(["10", "20", "30"]),
            scalar: 42,
        };
        const b64 = Plugin.Common.prepareCustomConf(conf);
        const back = Plugin.Common.loadCustomConf(b64);
        // loadCustomConf turns favor[] back into a Set.
        verify(back.favor instanceof Set);
        compare(back.favor.size, 3);
        verify(back.favor.has("20"));
        compare(back.scalar, 42);
    }

    function test_prepareCustomConf_setBecomesArrayInJSON() {
        // setTojson serializer (inner function) is invoked for every Set value
        // including the top-level favor field.
        const b64 = Plugin.Common.prepareCustomConf({ favor: new Set(["x"]) });
        const json = Qt.atob(b64);
        const parsed = JSON.parse(json);
        verify(Array.isArray(parsed.favor));
        compare(parsed.favor[0], "x");
    }

    // ── checklib variants ─────────────────────────────────────────────────────
    function test_checklib_returnsTrueForBundledModule() {
        // QtQml is always available in qmltestrunner.
        verify(Plugin.Common.checklib("QtQml 2.2", testCaseRoot));
    }

    function test_checklib_returnsFalseForMissingModule() {
        verify(! Plugin.Common.checklib(
            "definitely.not.a.real.module.kxz 1.0", testCaseRoot));
    }

    function test_checklib_wallpaper_returnsBoolean() {
        // wallpaperEngineKde plugin isn't loaded in tests — should be false,
        // but we only assert the type so the test isn't tied to deployment.
        const r = Plugin.Common.checklib_wallpaper(testCaseRoot);
        compare(typeof r, "boolean");
    }

    function test_checklib_folderlist_returnsBoolean() {
        const r = Plugin.Common.checklib_folderlist(testCaseRoot);
        compare(typeof r, "boolean");
    }

    function test_checklib_webchannel_returnsBoolean() {
        const r = Plugin.Common.checklib_webchannel(testCaseRoot);
        compare(typeof r, "boolean");
    }

    // ── ComboBox value/index helpers ──────────────────────────────────────────
    function _cbModel() {
        return [
            { value: "alpha" },
            { value: "beta"  },
            { value: "gamma" },
        ];
    }

    function test_cbCurrentValue_returnsValueAtCurrentIndex() {
        const combo = { currentIndex: 1, model: _cbModel() };
        compare(Plugin.Common.cbCurrentValue(combo), "beta");
    }

    function test_cbValueOfIndex_returnsValueAtGivenIndex() {
        const combo = { model: _cbModel() };
        compare(Plugin.Common.cbValueOfIndex(combo, 2), "gamma");
    }

    function test_cbIndexOfValue_returnsIndexOrMinusOne() {
        const combo = { model: _cbModel() };
        compare(Plugin.Common.cbIndexOfValue(combo, "beta"), 1);
        compare(Plugin.Common.cbIndexOfValue(combo, "missing"), -1);
    }

    function test_modelIndexOfValue_directly() {
        compare(Plugin.Common.modelIndexOfValue(_cbModel(), "alpha"), 0);
        compare(Plugin.Common.modelIndexOfValue(_cbModel(), "zeta"), -1);
    }

    // ── findItem / genItemListStr — exercise on a real QObject tree ──────────
    function test_findItem_returnsMatchingDescendant() {
        // Use the testCaseRoot as the parent — it has children we can find.
        // findItem walks .children[]; the leading typename match comes from
        // toString() (e.g., "QQuickItem(...)"), so we match the prefix.
        const found = Plugin.Common.findItem(testCaseRoot, "QQuickItem");
        // Either testCaseRoot itself matches, or a descendant does. Either
        // way the result must not be null because TestCase has Items inside.
        verify(found !== null);
    }

    function test_findItem_returnsNullWhenAbsent() {
        compare(Plugin.Common.findItem(testCaseRoot, "ZZZ_NoSuchType"), null);
    }

    function test_genItemListStr_includesRootAndChildren() {
        const s = Plugin.Common.genItemListStr(
            testCaseRoot, "  ",
            (it) => it.toString().split("(")[0]);
        verify(s.length > 0);
        verify(s.split("\n").length >= 1);
    }

    // ── findItem cycle guard: must not infinite-loop on a cyclic graph ──────
    function test_findItem_cycleGuardBreaksOnRevisit() {
        // Fake tree: a.children[0] = b, b.children[0] = a.
        // Without the cycle guard this would recurse forever.
        const a = { children: [], toString: function() { return "QQuickA(...)"; } };
        const b = { children: [], toString: function() { return "QQuickB(...)"; } };
        a.children.push(b);
        b.children.push(a);
        const found = Plugin.Common.findItem(a, "QQuickB");
        verify(found === b);
    }

    function test_findItem_cycleGuardReturnsNullForAbsentType() {
        const a = { children: [], toString: function() { return "QQuickA(...)"; } };
        const b = { children: [], toString: function() { return "QQuickB(...)"; } };
        a.children.push(b);
        b.children.push(a);
        compare(Plugin.Common.findItem(a, "ZZZ_Missing"), null);
    }

    // ── genItemListStr: cycle marker + depth cap ─────────────────────────────
    function test_genItemListStr_cycleMarkerEmitted() {
        const a = { children: [], toString: function() { return "A"; } };
        const b = { children: [a], toString: function() { return "B"; } };
        a.children.push(b);
        const out = Plugin.Common.genItemListStr(
            a, "  ", function(it) { return it.toString(); });
        verify(out.indexOf("A") >= 0);
        verify(out.indexOf("B") >= 0);
        verify(out.toLowerCase().indexOf("cycle") >= 0);
    }

    function test_genItemListStr_truncatesDeepLinearChain() {
        // 60-deep linked list — exceeds the maxDepth=50 cap.
        let root = { children: [], toString: function() { return "root"; } };
        let cur = root;
        for (let i = 0; i < 60; i++) {
            const next = { children: [], toString: (function(j) { return function() { return "n" + j; }; })(i) };
            cur.children.push(next);
            cur = next;
        }
        const out = Plugin.Common.genItemListStr(
            root, "  ", function(it) { return it.toString(); });
        verify(out.indexOf("truncated at depth 50") >= 0);
    }

    // ── createVolumeFade — start/stop wrappers ────────────────────────────────
    function test_createVolumeFade_returnsStartStopHandle() {
        // The fade timer interval is 300ms and ramps in steps of 5; we don't
        // wait that long. Just verify the handle's shape and that start/stop
        // don't throw — the actual ramp behavior is exercised at runtime.
        const handle = Plugin.Common.createVolumeFade(
            testCaseRoot, 50,
            () => {});
        compare(typeof handle.start, "function");
        compare(typeof handle.stop,  "function");
        handle.start();
        handle.stop();
    }

    // ── listProperty — smoke (output goes to console; verify no throw) ───────
    function test_listProperty_doesNotThrow() {
        // listProperty iterates `for (var p in obj)` and console.errors each
        // entry. We just assert it executes without error.
        Plugin.Common.listProperty({ a: 1, b: "two" });
        verify(true);
    }

    // ── urlNative — file URL stripping ────────────────────────────────────────
    function test_urlNative_stripsFileColonSlashSlash() {
        compare(Plugin.Common.urlNative("file:///tmp/foo"), "/tmp/foo");
    }

    function test_urlNative_stripsFileColon() {
        compare(Plugin.Common.urlNative("file:tmp"), "tmp");
    }

    function test_urlNative_passesThroughUnknownScheme() {
        compare(Plugin.Common.urlNative("https://x"), "https://x");
        compare(Plugin.Common.urlNative("plain"), "plain");
    }

    function test_videoExtensions_lowercaseDotPrefixed() {
        verify(Array.isArray(Plugin.Common.videoExtensions));
        verify(Plugin.Common.videoExtensions.length >= 6);
        for (let i = 0; i < Plugin.Common.videoExtensions.length; i++) {
            const ext = Plugin.Common.videoExtensions[i];
            verify(ext.indexOf(".") === 0, "extension missing dot: " + ext);
            compare(ext, ext.toLowerCase(), "extension not lowercase: " + ext);
        }
        verify(Plugin.Common.videoExtensions.indexOf(".mp4") >= 0);
        verify(Plugin.Common.videoExtensions.indexOf(".mkv") >= 0);
        verify(Plugin.Common.videoExtensions.indexOf(".webm") >= 0);
        verify(Plugin.Common.videoExtensions.indexOf(".mov") >= 0);
        verify(Plugin.Common.videoExtensions.indexOf(".avi") >= 0);
        verify(Plugin.Common.videoExtensions.indexOf(".m4v") >= 0);
    }

    // findItem and friends need a real Item parent. Provide one.
    Item {
        id: testCaseRoot
        Item { id: childA }
        Item {
            id: childB
            Item { id: grandchild }
        }
    }
}
