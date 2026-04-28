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

    function test_genFilter_unselectedTagExcludesItem() {
        const filters = [
            { type: "type",          key: "scene", value: 1 },
            { type: "contentrating", key: "Everyone", value: 1 },
            { type: "favor",         key: "favor", value: 0 },
            { type: "tags",          key: "Anime", value: 0 }, // Anime de-selected
            { type: "tags",          key: "Game",  value: 1 },
        ];
        const f = Plugin.Common.filterModel.genFilter(filters);
        verify(! f({ type: "scene", contentrating: "Everyone", favor: false,
                      tags: [{ key: "Anime" }], playlists: [] }));
        verify(f({ type: "scene", contentrating: "Everyone", favor: false,
                    tags: [{ key: "Game" }], playlists: [] }));
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
}
