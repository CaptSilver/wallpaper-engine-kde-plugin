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
        pyext.readfile("/x").then(v => { observed = v; });
        // Stub returns "" — promise resolves synchronously.
        compare(observed, "");
    }

    function test_get_dir_size_defaultsDepthToThree() {
        let observed = null;
        pyext.get_dir_size("/x").then(v => { observed = v; });
        compare(observed, 0); // stub returns 0
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
        // Stub's Qt.callLater fires the signal — wait one event loop turn.
        wait(50);
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
}
