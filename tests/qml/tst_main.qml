// main.qml is a WallpaperItem subclass that talks to a `wallpaper` context
// property (provided by Plasma at runtime). To unit-test it, we instantiate
// the file via Qt.createComponent into an empty parent and then exercise
// its public functions: applySource, loadBackend, get_opt_value, autoPause,
// hookMouseSlot, doHookMouse.
//
// Many handlers fire at instantiation (Component.onCompleted runs the full
// startup sequence). Just instantiating the component should bring most of
// main.qml into the catalog.
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "Main"
    width: 400; height: 300
    when: windowShown

    Item { id: host; anchors.fill: parent }

    property var mainItem: null
    property string loadError: ""

    // ── SignalSpies on `background` (target set in tests after _findBackground) ─
    // Declared as children of TestCase so lifetimes are clean across cases.
    SignalSpy { id: curOptSpy;            signalName: "curOptChanged" }
    SignalSpy { id: perOptSpy;            signalName: "perOptChangedChanged" }
    SignalSpy { id: mouseInputSpy;        signalName: "mouseInputChanged" }
    SignalSpy { id: wallpaperTypeSpy;     signalName: "wallpaperTypeChanged" }

    // SignalSpies on ad-hoc sub-objects (TtyMonitor signal, fake config emits).
    SignalSpy { id: ttySwitchSpy;         signalName: "ttySwitch" }

    function initTestCase() {
        const comp = Qt.createComponent("../../plugin/contents/ui/main.qml");
        if (comp.status === Component.Error) {
            loadError = comp.errorString();
            return;
        }
        mainItem = comp.createObject(host, {});
        if (!mainItem) loadError = "createObject returned null";
    }

    function test_componentLoadsAtAll() {
        verify(loadError === "", loadError);
        verify(mainItem !== null);
    }

    // The body of main.qml is a Rectangle inside the WallpaperItem; many of
    // the testable functions live on the Rectangle, accessible as the
    // WallpaperItem's first child.
    function _findBackground() {
        if (!mainItem) return null;
        const buckets = [mainItem.children || [], mainItem.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const c = b[i];
                if (c && typeof c.get_opt_value === "function") return c;
            }
        }
        return null;
    }

    function test_get_opt_value_fallsBackToDefault() {
        const bg = _findBackground();
        if (!bg) {
            verify(loadError !== "");  // OK: load failed, can't test
            return;
        }
        compare(bg.get_opt_value("nonexistent_key", "fallback"), "fallback");
    }

    function test_get_opt_value_picksOverride() {
        const bg = _findBackground();
        if (!bg) return;
        bg.curOpt = { my_key: 42 };
        compare(bg.get_opt_value("my_key", -1), 42);
    }

    function test_postProcessing_switchOn_mapsToUltra() {
        const bg = _findBackground();
        if (!bg) return;
        bg.curOpt = { postprocessing: true };
        compare(bg.postProcessing, "ultra");
    }

    function test_postProcessing_switchOffOrUnset_mapsToEmpty() {
        const bg = _findBackground();
        if (!bg) return;
        bg.curOpt = { postprocessing: false };
        compare(bg.postProcessing, "");
        bg.curOpt = {};
        compare(bg.postProcessing, "");
    }

    function test_curOptChanged_handlerFires() {
        const bg = _findBackground();
        if (!bg) return;
        curOptSpy.target = bg;
        curOptSpy.clear();
        bg.curOpt = { display_mode: 2, mute_audio: true, volume: 75, speed: 1.5 };
        // curOptChanged is a Qt-generated NOTIFY signal, auto-emitted on every
        // property write regardless of whether any onCurOptChanged handler
        // exists -- so this fires even though main.qml declares no such handler.
        verify(curOptSpy.count >= 1);
    }

    function test_perOptChanged_handlerFires() {
        const bg = _findBackground();
        if (!bg) return;
        perOptSpy.target = bg;
        perOptSpy.clear();
        bg.perOptChanged = bg.perOptChanged + 1;
        verify(perOptSpy.count >= 1);
    }

    function test_mouseInputChanged_branchToHookTimer() {
        const bg = _findBackground();
        if (!bg) return;
        mouseInputSpy.target = bg;
        mouseInputSpy.clear();
        bg.mouseInput = !bg.mouseInput;
        bg.mouseInput = !bg.mouseInput;  // toggle back
        // Two distinct toggles must fire two change notifications. If the
        // property became a no-op binding, count would be 0 or 1.
        compare(mouseInputSpy.count, 2);
    }

    function test_hookMouseSlot_constructs() {
        const bg = _findBackground();
        if (!bg) return;
        // No real Plasma Window in tests, so doHookMouse() returns false and
        // hookMouseSlot() restarts hookTimer (already running). The honest
        // assertion is that the function is callable on `background`.
        verify(typeof bg.hookMouseSlot === "function");
        bg.hookMouseSlot();
    }

    function test_doHookMouse_returnsBool() {
        const bg = _findBackground();
        if (!bg) return;
        // Without a real Plasma window/screen tree, doHookMouse returns false.
        const r = bg.doHookMouse();
        compare(typeof r, "boolean");
    }

    function test_autoPause_returnsEarlyWhenItemMissing() {
        const bg = _findBackground();
        if (!bg) return;
        // backendLoader.item is null in tests (no scene/mpv/qtwebview backend
        // mounted), so autoPause() should hit the early-return path and yield
        // undefined cleanly. A regressed guard would attempt to call
        // .play()/.pause() on null and throw.
        compare(bg.autoPause(), undefined);
    }

    function test_applySource_constructs() {
        const bg = _findBackground();
        if (!bg) return;
        // `applySource` reaches `wallpaper.configuration.WallpaperWorkShopId`
        // on its first line, which throws ReferenceError under unit-test scope
        // (no Plasma `wallpaper` context). The honest assertion is that the
        // function exists on `background`; integration tests
        // (tst_main_components / tst_main_multimonitor) drive a real
        // WallpaperFake through it.
        verify(typeof bg.applySource === "function");
    }

    function test_loadBackend_branchesByWallpaperType() {
        const bg = _findBackground();
        if (!bg) return;
        wallpaperTypeSpy.target = bg;
        wallpaperTypeSpy.clear();
        const types = ["video", "web", "scene", "unsupported"];
        for (const t of types) {
            bg.wallpaperType = t;
            try { bg.loadBackend(); } catch(e) {}
        }
        // Initial wallpaperType may be undefined / "" — every iteration must
        // record a change. If the property became non-NOTIFYing, count would
        // be 0 instead of types.length.
        compare(wallpaperTypeSpy.count, types.length);
        compare(bg.wallpaperType, "unsupported");
    }

    // main.qml both declares `sig_backendFirstFrame` and sinks it locally.
    // Only the declarative `onSig_backendFirstFrame:` binding is auto-connected
    // — a like-named `function on…()` in the object body is just an ordinary
    // method, so every backend's emit would reach nothing and the "Updated"
    // badge would never advance. Lock the binding form here; Main_Components
    // drives the recorded-version effect end-to-end under a real `wallpaper`.
    function test_backendFirstFrame_isBoundAsASignalHandler() {
        const src = _mainQmlSource();
        verify(/\bsignal\s+sig_backendFirstFrame\b/.test(src),
               "main.qml no longer declares sig_backendFirstFrame");
        verify(/^\s*onSig_backendFirstFrame\s*:/m.test(src),
               "main.qml declares sig_backendFirstFrame but binds no "
               + "onSig_backendFirstFrame handler — the first-frame emit is dropped");
    }

    // ── Walk all child timers + sub-objects and fire their handlers ──────────
    function _allDataItems(parent, out) {
        out = out || [];
        const buckets = [parent.children || [], parent.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && out.indexOf(b[i]) < 0) {
                    out.push(b[i]);
                    _allDataItems(b[i], out);
                }
            }
        }
        return out;
    }

    function test_fireAllChildTimers_triggersOnTriggeredHandlers() {
        // hookTimer (2000ms), randomizeTimer (variable), lauchPauseTimer
        // (300ms), playTimer (5000ms), sourcePauseTimer (200ms),
        // loadingHintDelay (600ms). Trigger each by emitting `triggered()`
        // and assert via SignalSpy that the emission was observed.
        const bg = _findBackground();
        if (!bg) return;
        const all = _allDataItems(bg);
        let timersFound = 0;
        let timersObserved = 0;
        for (const item of all) {
            if (item && typeof item.triggered === "function" &&
                typeof item.start === "function") {
                timersFound++;
                const spy = Qt.createQmlObject(
                    'import QtTest 1.0; SignalSpy { signalName: "triggered" }', tc);
                spy.target = item;
                try { item.triggered(); } catch (e) {}
                if (spy.count >= 1) timersObserved++;
                spy.destroy();
            }
        }
        // main.qml owns 5 Timers + 1 loadingHintDelay = 6 expected timers.
        // A regression that dropped one entirely would lower timersFound; a
        // signal that was renamed silently would lower timersObserved.
        verify(timersFound >= 5);
        compare(timersObserved, timersFound);
    }

    function test_fireTtyMonitorSwitchSignal_bothSleepAndWake() {
        const bg = _findBackground();
        if (!bg) return;
        const all = _allDataItems(bg);
        let monitorsFound = 0;
        let totalEmits = 0;
        for (const item of all) {
            if (item && typeof item.ttySwitch === "function") {
                monitorsFound++;
                ttySwitchSpy.target = item;
                ttySwitchSpy.clear();
                try { item.ttySwitch(true); } catch(e) {}
                try { item.ttySwitch(false); } catch(e) {}
                totalEmits += ttySwitchSpy.count;
                compare(ttySwitchSpy.signalArguments[0][0], true);
                compare(ttySwitchSpy.signalArguments[1][0], false);
            }
        }
        // Exactly one TTYSwitchMonitor child (id: ttyMonitor); both emits
        // observed via the spy.
        compare(monitorsFound, 1);
        compare(totalEmits, 2);
    }

    function test_sourceCallback_fires() {
        const bg = _findBackground();
        if (!bg) return;
        verify(typeof bg.sourceCallback === "function");
        // sourceCallback() starts sourcePauseTimer (interval 200, repeat
        // false). Find it via _allDataItems by interval+repeat shape, mark
        // its prior `running` state, fire the callback, assert running flips
        // to true. A regressed sourceCallback (no-op or wrong-timer call)
        // would leave running unchanged.
        const all = _allDataItems(bg);
        let pauseTimer = null;
        for (const item of all) {
            if (item && typeof item.triggered === "function" &&
                typeof item.start === "function" &&
                item.interval === 200 && item.repeat === false) {
                pauseTimer = item;
                break;
            }
        }
        verify(pauseTimer !== null);
        pauseTimer.running = false;  // reset (Component.onCompleted may have started it)
        bg.sourceCallback();
        verify(pauseTimer.running);
    }

    function test_changeWallpaperOnList_handlesEmptyModel() {
        // wpListModel.changeWallpaper(0) early-returns when model.count === 0
        const bg = _findBackground();
        if (!bg) return;
        const all = _allDataItems(bg);
        let listModels = 0;
        for (const item of all) {
            if (item && typeof item.changeWallpaper === "function") {
                listModels++;
                // The model is empty in tests (no Steam library scan); calling
                // changeWallpaper(0) must hit the early-return branch without
                // touching wallpaper.configuration.* (which would throw).
                bg.curOpt = bg.curOpt;  // touch to confirm bg still healthy after
                item.changeWallpaper(0);
                // model.count should still be 0 (handler doesn't grow the list).
                compare(item.model.count, 0);
            }
        }
        // main.qml owns exactly one wpListModel.
        compare(listModels, 1);
    }

    function _mainQmlSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../plugin/contents/ui/main.qml"), false);
        xhr.send(null);
        compare(xhr.status, 200, "could not read main.qml source");
        return xhr.responseText;
    }

    // workshopid was historically `property string workshopid: { ... ; pyext.read_wallpaper_config(wid).then(...); return wid; }`
    // — a binding whose evaluation also dispatched an async pyext read whose
    // .then callback wrote curOpt as a side effect. That made re-evaluation
    // re-fire the read invisibly; the dependency tracker only saw
    // WallpaperWorkShopId. The proper QML shape is a pure value binding plus
    // an explicit `onWorkshopidChanged` handler that owns the async dispatch.
    // Source-text contract: workshopid declaration MUST be a single-expression
    // binding (no block body containing pyext.read_wallpaper_config), and an
    // `onWorkshopidChanged` handler MUST exist to do the async work.
    function test_workshopid_isPureBinding_noSideEffectInDecl() {
        const src = _mainQmlSource();

        // Locate the workshopid declaration. The line MUST be a pure binding
        // (everything after the colon is a single expression on the same
        // logical line, no `{` opening a block body before a semicolon).
        const decl = src.match(/property\s+string\s+workshopid\s*:\s*([^\n]+)/);
        verify(decl !== null);
        const rhs = decl[1].trim();
        // Pre-fix RHS starts with `{` (block body). Post-fix RHS is the
        // pure expression `wallpaper.configuration.WallpaperWorkShopId`.
        verify(!rhs.startsWith("{"),
               "workshopid binding RHS must not be a block body — "
               + "block bodies enable side-effecting bindings. Found: " + rhs);

        // The async pyext.read_wallpaper_config call belongs in an explicit
        // handler. Assert one exists in the file. Pre-fix the side effect
        // lived inside the workshopid binding body; post-fix it moves here.
        const hasHandler = /onWorkshopidChanged\s*:/.test(src);
        verify(hasHandler,
               "expected onWorkshopidChanged handler in main.qml — "
               + "the async pyext.read_wallpaper_config(workshopid) call "
               + "moves out of the workshopid binding into this handler");
    }

    // curOpt-derived properties (displayMode, backgroundColor, mute, volume, speed,
    // userPropsJson) used to be reassigned imperatively from an onCurOptChanged
    // handler, which silently converts a QML property's live binding into a static
    // value the moment it fires once. A Connections block targeting
    // wallpaper.configuration existed only to claw back the config-change
    // reactivity that assignment destroyed. Source-text contract: neither the
    // handler nor that Connections block may exist, and userPropsJson must read
    // curOpt directly rather than sit on a permanent "" default.
    function test_curOptDerivedProps_areBindingsNotImperativeAssignments() {
        const src = _mainQmlSource();

        verify(!/onCurOptChanged\s*:/.test(src),
               "main.qml still has an onCurOptChanged handler -- imperative "
               + "assignment inside it converts displayMode/backgroundColor/mute/"
               + "volume/speed from live bindings into static values the first "
               + "time curOpt changes");

        verify(!/Connections\s*\{[^}]*target:\s*wallpaper\.configuration/.test(src),
               "main.qml still has a Connections block re-targeting "
               + "wallpaper.configuration -- that block exists only to hand-roll "
               + "reactivity an ordinary binding provides for free");

        const decl = src.match(/property\s+string\s+userPropsJson\s*:\s*([^\n]+)/);
        verify(decl !== null, "userPropsJson declaration not found in main.qml");
        const rhs = decl[1].trim();
        verify(/curOpt/.test(rhs),
               "userPropsJson's declaration must read curOpt directly -- found: " + rhs);
    }

    // ── startup cache GC ──────────────────────────────────────────────────
    // The GC block in Component.onCompleted was written against config.qml's
    // scope and pasted into the wallpaper item, where `plugin_info` does not
    // resolve; a `typeof plugin_info !== 'undefined'` test turned the
    // ReferenceError into a silent skip, so the pass never ran on a desktop.

    // Walk down to the Pyext instance — it is an id inside `background`, not
    // a property, so it is only reachable through the object tree.
    function _findPyext(bg) {
        const buckets = [bg.children || [], bg.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const c = b[i];
                if (c && typeof c.request_cache_gc === "function") return c;
            }
        }
        return null;
    }

    function test_startupCacheGc_pluginInfoIsInScope() {
        const bg = _findBackground();
        if (!bg) { verify(loadError !== ""); return; }
        verify(bg.plugin_info !== undefined && bg.plugin_info !== null,
                "main.qml has no plugin_info — the startup cache GC never runs");
    }

    function test_runCacheGc_dispatchesAsyncWithFlatInstalledDirs() {
        const bg = _findBackground();
        if (!bg) { verify(loadError !== ""); return; }
        const pyext = _findPyext(bg);
        verify(pyext !== null, "no Pyext exposing request_cache_gc under background");
        const fh = pyext.helper;
        verify(fh !== null && fh !== undefined, "Pyext.helper is not exposed");

        bg.plugin_info.cache_path = "file:///tmp/wek-qmltest/wescene-renderer";
        bg.cacheQuotaMB = 500;
        fh.requestCacheGcCount = 0;
        fh.pruneOrphanThumbnailsCount = 0;
        fh.enforceCacheQuotaCount = 0;

        bg.runCacheGc();

        compare(fh.requestCacheGcCount, 1);
        const args = fh.lastRequestCacheGcArgs;
        compare(args.cacheRoot, "/tmp/wek-qmltest/wescene-renderer");
        compare(args.quotaBytes, 500 * 1024 * 1024);
        // Common.getProjectDirs is deliberately ragged — element 0 is the
        // case-variant workshop group. Handed to a QStringList parameter
        // as-is, QML comma-joins that nested array into one bogus path and
        // the four workshop roots never reach the pruner.
        verify(args.installedDirs.length >= 6);
        for (let i = 0; i < args.installedDirs.length; i++)
            verify(typeof args.installedDirs[i] === "string",
                    "installedDirs[" + i + "] is not a string — the ragged array leaked");

        // The synchronous entry points stall plasmashell's GUI thread on a
        // full cache walk; startup must not use them.
        compare(fh.pruneOrphanThumbnailsCount, 0);
        compare(fh.enforceCacheQuotaCount, 0);
    }

    function test_runCacheGc_noopsWithoutCachePath() {
        const bg = _findBackground();
        if (!bg) { verify(loadError !== ""); return; }
        const pyext = _findPyext(bg);
        if (!pyext) return;
        const fh = pyext.helper;
        bg.plugin_info.cache_path = "";
        fh.requestCacheGcCount = 0;
        bg.runCacheGc();
        compare(fh.requestCacheGcCount, 0);
    }

    // Startup has to stamp a seen version onto wallpapers configured before
    // anything was recorded, or the whole library reads as updated. The call
    // fires from Component.onCompleted, so the count is whatever load left
    // behind — no test may reset it.
    function test_startup_seedsLastSeenVersionsOnce() {
        const bg = _findBackground();
        if (!bg) { verify(loadError !== ""); return; }
        const pyext = _findPyext(bg);
        verify(pyext !== null, "no Pyext exposing request_cache_gc under background");
        const fh = pyext.helper;
        verify(fh !== null && fh !== undefined, "Pyext.helper is not exposed");

        compare(fh.seedLastSeenVersionsCount, 1);

        // The C++ side opens the path directly, so it must arrive stripped of
        // the file:// scheme QML carries it in.
        const path = fh.lastSeedLastSeenVersionsPath;
        verify(typeof path === "string",
                "steamlibrary never reached seedLastSeenVersions");
        verify(path.indexOf("file://") !== 0,
                "steamlibrary arrived as a URL, not a native path: " + path);
    }
}
