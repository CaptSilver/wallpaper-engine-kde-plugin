import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    name: "Pyext"
    when: windowShown

    Plugin.Pyext { id: pyext }

    function test_alwaysReadyFlags() {
        verify(pyext.ok);
        compare(pyext.log, "");
        compare(pyext.version, "native");
    }

    // ── _makePromise wrapper round-trip ──────────────────────────────────────
    function test_promiseThenChainsValues() {
        let observed = null;
        pyext._makePromise(42).then(v => { observed = v; });
        compare(observed, 42);
    }

    function test_promiseThenChainAllowsTransform() {
        let observed = null;
        pyext._makePromise(1).then(v => v + 1).then(v => { observed = v; });
        compare(observed, 2);
    }

    function test_promiseCatchIsNoOpForSyncValues() {
        let caught = false;
        pyext._makePromise(7).catch(_ => { caught = true; });
        verify(! caught); // synchronous values never invoke catch
    }

    // ── FFI bridges return promises wrapping stub values ─────────────────────
    function test_qwebChannelSourceReturnsString() {
        compare(typeof pyext.qwebChannelSource(), "string");
    }

    function test_patchedHtmlReturnsString() {
        compare(typeof pyext.patchedHtml("/foo"), "string");
    }

    function test_readfileReturnsPromise() {
        let observed = null;
        const p = pyext.readfile("/x");
        verify(p && typeof p.then === "function"); // real Promise now
        p.then(v => { observed = v; });
        // Stub's Qt.callLater fires fileReadReady — poll like the
        // generate_thumbnail / get_dir_size resolves-on-signal tests.
        tryVerify(() => observed === "", 2000);
        compare(observed, "");
    }

    function test_get_dir_size_defaultsDepthToThree() {
        let observed = null;
        const p = pyext.get_dir_size("/x"); // depth defaults to 3
        verify(p && typeof p.then === "function"); // real Promise now
        p.then(v => { observed = v; });
        // Stub fires dirSizeReady(path, 0) via Qt.callLater — poll like the
        // generate_thumbnail resolves-on-signal test.
        tryVerify(() => observed === 0, 2000);
        compare(observed, 0);
    }

    function test_get_folder_list_defaultsOptToEmpty() {
        let observed = null;
        pyext.get_folder_list("/x").then(v => { observed = v; });
        verify(Array.isArray(observed));
    }

    function test_read_wallpaper_config_returnsPromiseObject() {
        let observed = null;
        pyext.read_wallpaper_config("12345").then(v => { observed = v; });
        compare(typeof observed, "object");
    }

    function test_write_wallpaper_config_resolvesNull() {
        let observed = "before";
        pyext.write_wallpaper_config("12345", { x: 1 }).then(v => { observed = v; });
        compare(observed, null);
    }

    function test_reset_wallpaper_config_resolvesNull() {
        let observed = "before";
        pyext.reset_wallpaper_config("12345").then(v => { observed = v; });
        compare(observed, null);
    }

    function test_read_active_bindings_returnsPromiseObject() {
        let observed = null;
        pyext.read_active_bindings("12345").then(v => { observed = v; });
        compare(typeof observed, "object");
    }

    function test_scan_video_folder_returnsPromise() {
        let observed = null;
        pyext.scan_video_folder("/tmp").then(v => { observed = v; });
        verify(Array.isArray(observed));
    }

    function test_generate_thumbnail_returnsRealPromise() {
        const p = pyext.generate_thumbnail("/x.mp4", "/tmp/out.jpg", 0.5);
        verify(p && typeof p.then === "function");
    }

    function test_generate_thumbnail_resolvesOnSignal() {
        let resolvedWith = null;
        const p = pyext.generate_thumbnail("/x.mp4", "/tmp/out.jpg", 0.5);
        p.then((outPath) => { resolvedWith = outPath; });
        // Stub's Qt.callLater fires the signal — poll until the promise
        // resolves into the local JS var (tryCompare can't poll a JS var).
        tryVerify(() => resolvedWith === "/tmp/out.jpg", 2000);
        compare(resolvedWith, "/tmp/out.jpg");
    }

    function test_clear_cache_returnsPromiseResolvingToBool() {
        // Stub returns true; pyext.clear_cache wraps it in the promise
        // shim. Both the wrapper and the underlying FFI call get
        // exercised.
        let observed = null;
        pyext.clear_cache("/tmp/cache").then(v => { observed = v; });
        compare(observed, true);
    }

    // Look up the inner FileHelper stub on the Pyext. Pyext is an Item; the
    // stub is in its `data` (or `children`) bucket. Mirrors the _findInner
    // idiom used in tst_backend_qtwebview.
    function _findFileHelper() {
        const buckets = [pyext.children || [], pyext.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && typeof b[i].addReadRoot === "function") return b[i];
            }
        }
        return null;
    }

    // The seedRoots binding must propagate to the inner FileHelper: each
    // assign clears the existing allowlist + re-adds every non-empty entry.
    // This is the QML-side contract for SEC-READFILE1 — wallpapers can't
    // change the C++ allowlist except via the explicit seedRoots reassign.
    function test_seedRoots_propagatesToFileHelperOnAssign() {
        const fh = _findFileHelper();
        verify(fh !== null);
        const c0 = fh.clearReadRootsCount;
        const a0 = fh.addReadRootCount;
        pyext.seedRoots = ["/tmp/root1", "/tmp/root2"];
        compare(fh.clearReadRootsCount, c0 + 1);
        compare(fh.addReadRootCount, a0 + 2);
        compare(fh.lastAddReadRootPath, "/tmp/root2");
    }

    // Empty / null entries in seedRoots must be skipped (the binding in
    // main.qml builds the array conditionally, so an unset SteamLibraryPath
    // produces an empty string entry — the QML side filters it out before
    // the C++ addReadRoot would warn about a non-existent path).
    function test_seedRoots_emptyEntriesAreSkipped() {
        const fh = _findFileHelper();
        verify(fh !== null);
        const a0 = fh.addReadRootCount;
        pyext.seedRoots = ["/tmp/realA", "", "/tmp/realB"];
        // 2 real entries + the skipped empty one; addReadRoot only fires twice.
        compare(fh.addReadRootCount, a0 + 2);
    }

    // ── Cache GC / quota / workshop-manifest passthroughs ─────────────────
    function test_prune_orphan_thumbnails_forwardsArgsAndDefaultsUndefinedToEmptyArrays() {
        const fh = _findFileHelper();
        verify(fh !== null);
        const c0 = fh.pruneOrphanThumbnailsCount;
        const freed = pyext.prune_orphan_thumbnails("/cache/root");
        compare(fh.pruneOrphanThumbnailsCount, c0 + 1);
        compare(fh.lastPruneOrphanThumbnailsArgs.cacheRoot, "/cache/root");
        compare(fh.lastPruneOrphanThumbnailsArgs.installedDirs, []);
        compare(fh.lastPruneOrphanThumbnailsArgs.videoDirs, []);
        compare(freed, 0);
    }

    function test_enforce_cache_quota_forwardsRootsAndQuota() {
        const fh = _findFileHelper();
        verify(fh !== null);
        const c0 = fh.enforceCacheQuotaCount;
        pyext.enforce_cache_quota(["/cache/root"], 12345);
        compare(fh.enforceCacheQuotaCount, c0 + 1);
        compare(fh.lastEnforceCacheQuotaArgs.roots, ["/cache/root"]);
        compare(fh.lastEnforceCacheQuotaArgs.quotaBytes, 12345);
    }

    function test_enforce_cache_quota_force_forwardsRootsAndQuota() {
        const fh = _findFileHelper();
        verify(fh !== null);
        const c0 = fh.enforceCacheQuotaForceCount;
        pyext.enforce_cache_quota_force(["/cache/root"], 999);
        compare(fh.enforceCacheQuotaForceCount, c0 + 1);
        compare(fh.lastEnforceCacheQuotaForceArgs.roots, ["/cache/root"]);
        compare(fh.lastEnforceCacheQuotaForceArgs.quotaBytes, 999);
    }

    function test_video_thumb_dir_appendsVideoThumbsUnderNativeCacheRoot() {
        compare(pyext.video_thumb_dir("file:///tmp/cache"), "/tmp/cache/video-thumbs");
    }

    function test_read_workshop_manifest_forwardsPathAndReturnsObject() {
        const fh = _findFileHelper();
        verify(fh !== null);
        const c0 = fh.readWorkshopManifestCount;
        const manifest = pyext.read_workshop_manifest("/steam/library");
        compare(fh.readWorkshopManifestCount, c0 + 1);
        compare(fh.lastReadWorkshopManifestPath, "/steam/library");
        compare(typeof manifest, "object");
    }

    // The inner FileHelper's wallpaperDirChanged must forward through
    // Pyext's own signal of the same name (onWallpaperDirChanged in the
    // Connections block) — the QML-side WallpaperListModel connects to
    // pyext, not to the C++ FileHelper directly.
    SignalSpy {
        id: wallpaperDirChangedSpy
        target: pyext
        signalName: "wallpaperDirChanged"
    }

    function test_onWallpaperDirChanged_forwardsFromInnerFileHelper() {
        const fh = _findFileHelper();
        verify(fh !== null);
        wallpaperDirChangedSpy.clear();
        fh.wallpaperDirChanged("/tmp/new-wallpaper-dir");
        compare(wallpaperDirChangedSpy.count, 1);
        compare(wallpaperDirChangedSpy.signalArguments[0][0], "/tmp/new-wallpaper-dir");
    }
}
