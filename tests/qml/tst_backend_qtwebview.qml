import QtQuick
import QtTest
import QtWebEngine 1.10

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    name: "Backend_QtWebView"
    width: 200; height: 100
    when: windowShown

    BackgroundFake { id: background }

    // loadInfoShow recorder — production's onLoadingChanged failed branch
    // calls `webItem.parent.loadInfoShow(msg)` for the FIRST top-level
    // nav failure (QtWebView.qml:182-186). webItem's parent is this
    // TestCase, so the routed call lands here.
    property int    loadInfoShowCount: 0
    property string lastLoadInfoMsg:   ""
    function loadInfoShow(msg) {
        loadInfoShowCount += 1;
        lastLoadInfoMsg    = msg;
    }

    // patchedHtml + readfile recorders — production calls these from
    // loadWallpaper() and the webobj onLoadedChanged handler. Recording
    // here is test-local (no stub modification) and lets us assert the
    // forwarded call paths without relying on Chromium-internal observables.
    property int    patchedHtmlCount: 0
    property var    lastPatchedHtmlArg: undefined
    property int    readfileCount: 0
    property var    lastReadfileArg: undefined

    Backend.QtWebView {
        id: web
        source: "file:///tmp/fake_wallpaper.html"
        readfile: function(p) {
            // QtWebView reads project.json via readfile() to populate
            // userProperties. Return a parseable JSON string in a thenable.
            readfileCount  += 1;
            lastReadfileArg = p;
            return {
                then: function(cb) {
                    cb('{"general":{"properties":{"sliderProp":{"value":50}}}}');
                    return this;
                },
            };
        }
        patchedHtml: function(p) {
            patchedHtmlCount  += 1;
            lastPatchedHtmlArg = p;
            return "<html><body>stub</body></html>";
        }
        qwebChannelJs: "<<qwebchannel-js-stub-content>>".repeat(20);
    }

    SignalSpy { id: userPropsSpy;    signalName: "sigUserProperties"    }
    SignalSpy { id: generalPropsSpy; signalName: "sigGeneralProperties" }

    function test_loadWallpaper_callsPatchedHtmlEvenWhenScriptsNotReady() {
        // loadWallpaper() unconditionally invokes patchedHtml(filePath)
        // (QtWebView.qml:32) regardless of web._scriptsReady — that gate
        // only protects the onSourceChanged auto-fire path. So calling
        // it directly should always route through patchedHtml. We
        // observe via the test-local recorder.
        const n = patchedHtmlCount;
        web.loadWallpaper();
        compare(patchedHtmlCount, n + 1);
        verify(typeof lastPatchedHtmlArg === "string");
    }

    function test_play_pause_togglePausedFlag() {
        // play()  → web.paused = false  (QtWebView.qml:289-291)
        // pause() → web.paused = true   (QtWebView.qml:292-295)
        // The inner WebEngineView stub exposes `paused` as a plain bool
        // property; we read it back to confirm the toggle round-trips.
        const wev = _findWebEngineView();
        verify(wev !== null);
        web.pause();
        compare(wev.paused, true);
        web.play();
        compare(wev.paused, false);
    }

    function test_getMouseTargetReturnsBinding() {
        const t = web.getMouseTarget();
        verify(t !== undefined);
    }

    function test_userPropsJsonChange_earlyReturnsWhenWebobjUnloaded() {
        // onUserPropsJsonChanged early-returns when !webobj.loaded
        // (QtWebView.qml:46). The delta-emit code path that fires
        // webobj.sigUserProperties MUST be skipped — assert via SignalSpy
        // count.  (Reset loaded to false in case a prior alphabetic test
        // — e.g. test_audioBuffer / test_webobjLoaded — flipped it.)
        const webobj = _findWebobj();
        verify(webobj !== null);
        webobj.setLoaded(false);
        userPropsSpy.target = webobj;
        userPropsSpy.clear();
        background.userPropsJson = '{"sliderProp": 75}';
        compare(userPropsSpy.count, 0);
    }

    function test_fpsChange_earlyReturnsWhenWebobjUnloaded() {
        // onFpsChanged is guarded by `if(webobj.loaded)` (QtWebView.qml:70-75)
        // so loaded=false MUST suppress the sigGeneralProperties emission.
        // Reset loaded to false (prior tests may have flipped it).
        const webobj = _findWebobj();
        verify(webobj !== null);
        webobj.setLoaded(false);
        generalPropsSpy.target = webobj;
        generalPropsSpy.clear();
        background.fps = 60;
        compare(generalPropsSpy.count, 0);
    }

    function test_sourceChange_re_triggersLoadWallpaper() {
        // onSourceChanged calls loadWallpaper() iff web._scriptsReady
        // (QtWebView.qml:19-22). Component.onCompleted sets _scriptsReady
        // = true, so a fresh source assignment must trigger another
        // loadWallpaper → patchedHtml(newFilePath). Observe via the
        // patchedHtml recorder.
        const wev = _findWebEngineView();
        verify(wev !== null);
        verify(wev._scriptsReady);
        const n = patchedHtmlCount;
        web.source = "file:///tmp/another_wallpaper.html";
        compare(patchedHtmlCount, n + 1);
        verify(lastPatchedHtmlArg.indexOf("another_wallpaper.html") !== -1);
    }

    function _findInner(predicate) {
        const buckets = [web.children || [], web.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                if (b[i] && predicate(b[i])) return b[i];
            }
        }
        return null;
    }

    function _findWebEngineView() {
        return _findInner(c => typeof c.loadHtml === "function" &&
                               typeof c.audioMuted !== "undefined");
    }

    function _findWebobj() {
        return _findInner(c => c && typeof c.loaded !== "undefined" &&
                               typeof c.sigUserProperties === "function" &&
                               typeof c.sigGeneralProperties === "function");
    }

    function _findPauseImage() {
        return _findInner(c => c && typeof c.source !== "undefined" &&
                               typeof c.enabled !== "undefined" &&
                               c.enabled === false);
    }

    // ── WebEngineView.onLoadingChanged: 26 LOC handler — covers Failed +
    //    Succeeded branches plus the paused-true re-fire path ───────────────
    function test_webEngineOnLoadingChanged_succeededAndFailed() {
        const wev = _findWebEngineView();
        if (!wev) return;
        // Reset _firstLoadOk so the failed-then-succeeded ordering below
        // exercises the InfoShow path. Component.onCompleted may have
        // already flipped it, depending on stub init order.
        wev._firstLoadOk = false;

        // Failed first — production calls loadInfoShow when
        // !_firstLoadOk + parent supplies it (QtWebView.qml:176-187).
        const ls0 = loadInfoShowCount;
        const failedInfo = { status: 3, url: "", errorString: "broken" };
        wev.loadingChanged(failedInfo);
        compare(loadInfoShowCount, ls0 + 1);
        verify(lastLoadInfoMsg.indexOf("broken") !== -1);

        // Succeeded — sets _firstLoadOk=true, fires
        // background.sig_backendFirstFrame('QtWebEngine')
        // (QtWebView.qml:188-196).
        const ff0 = background.firstFrameCount;
        const succeededInfo = {
            status: 2,  // WebEngineView.LoadSucceededStatus
            url: "file:///tmp/x.html", errorString: "",
        };
        wev.loadingChanged(succeededInfo);
        compare(wev._firstLoadOk, true);
        compare(background.firstFrameCount, ff0 + 1);
        compare(background.lastFirstFrameName, "QtWebEngine");

        // Succeeded again while paused — should fire play() then pause()
        // (QtWebView.qml:191-194) so paused remains true at the end.
        wev.paused = true;
        wev.loadingChanged(succeededInfo);
        compare(wev.paused, true);
    }

    // ── WebAudioBridge.onAudioBuffer@93: relays a 128-sample audio
    //    array to the webobj. Only fires when webobj.loaded is true —
    //    a regression that drops the guard would push audio at an
    //    uninitialised proxy and crash in-page JS.
    function test_audioBuffer_onlyForwardedWhenWebobjLoaded() {
        const bridge = _findInner(c =>
            c && typeof c.audioBuffer === "function" &&
            typeof c.enabled !== "undefined");
        const webobj = _findInner(c =>
            c && typeof c.loaded !== "undefined" &&
            typeof c.sigAudio === "function");
        if (!bridge || !webobj) return;

        let relayed = 0;
        const conn = function(arr) { relayed += 1; };
        webobj.sigAudio.connect(conn);

        // Default state: loaded === false → handler must NOT relay.
        webobj.setLoaded(false);
        try { bridge.audioBuffer([0, 1, 2, 3]); } catch (e) {}
        compare(relayed, 0,
                "audio relay must be gated on webobj.loaded");

        // Flip loaded → relay should now fire.
        webobj.setLoaded(true);
        try { bridge.audioBuffer([4, 5, 6, 7]); } catch (e) {}
        compare(relayed, 1,
                "loaded webobj must receive audio samples");

        webobj.sigAudio.disconnect(conn);
    }

    // ── webobj.onLoadedChanged@91: fired when webobj.loaded toggles true.
    //    The 26 LOC body reads project.json via readfile() and emits
    //    sigUserProperties + sigGeneralProperties on the webobj. ──────────
    function test_webobjLoaded_triggersUserPropertyLoad() {
        // webobj is a SafeWallpaperBridge sibling of WebEngineView with a
        // `loaded` property and signals `sigUserProperties` +
        // `sigGeneralProperties`.  Reset loaded to false first — prior tests
        // (alphabetically: test_webEngineOnLoadingChanged...) may have
        // flipped it via setLoaded(true).
        const webobj = _findWebobj();
        verify(webobj !== null);
        webobj.setLoaded(false);
        userPropsSpy.target    = webobj;
        generalPropsSpy.target = webobj;
        userPropsSpy.clear();
        generalPropsSpy.clear();
        const rfn = readfileCount;

        // Set webItem.userPropsJson so the inner overrides loop runs too.
        web.userPropsJson = '{"sliderProp":42}';
        webobj.setLoaded(true);

        // Production reads project.json then emits BOTH signals on the
        // webobj (QtWebView.qml:114-131). The test's readfile() invokes
        // the .then() callback synchronously, so by this point all three
        // observables must have advanced.
        compare(readfileCount, rfn + 1);
        verify(lastReadfileArg.indexOf("project.json") !== -1);
        compare(userPropsSpy.count, 1);
        compare(generalPropsSpy.count, 1);
    }

    // ── WebUrlInterceptor (file:// sandbox) wiring ─────────────────────────
    // loadWallpaper() must call wallpaperInterceptor.setWallpaperBaseDir(baseDir)
    // BEFORE invoking patchedHtml / loadHtml, with the wallpaper's DIRECTORY
    // (not the file URL).  The QML stub for WebUrlInterceptor is a recorder.
    function test_loadWallpaper_callsSetWallpaperBaseDir_withDirPath() {
        function findInterceptor() {
            const buckets = [web.children || [], web.data || []];
            for (const b of buckets) {
                for (let i = 0; i < b.length; i++) {
                    const c = b[i];
                    if (c && typeof c.setWallpaperBaseDir === "function") return c;
                }
            }
            return null;
        }
        const it = findInterceptor();
        verify(it !== null, "WebUrlInterceptor sibling must exist");

        const n = it.setBaseDirCount;
        web.source = "file:///tmp/sec-web1-suite/index.html";
        // onSourceChanged → loadWallpaper() under _scriptsReady; advances.
        compare(it.setBaseDirCount, n + 1);
        verify(it.lastBaseDir.indexOf("/tmp/sec-web1-suite") !== -1,
            "interceptor base must be the wallpaper directory, not the file URL");
        verify(it.lastBaseDir.indexOf("index.html") === -1,
            "base must strip the filename");
    }

    // ── Feature-permission consent (geolocation, mic, camera, …) ──────────
    // Helper to build a fake Pyext whose read_wallpaper_config returns the
    // supplied object via a synchronous .then() (matches the QtWebView code
    // path which expects a promise-like).
    function _makeFakePyext(cfgReturn) {
        return {
            _writes: [],
            read_wallpaper_config: function(_id) {
                return { then: function(cb) { cb(cfgReturn); return this; } };
            },
            write_wallpaper_config: function(id, cfg) {
                this._writes.push({ id: id, cfg: cfg });
            },
        };
    }

    function test_featurePermissionRequested_noPriorDecision_promptsAndPersistsAllow() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        verify(typeof wev.grantFeaturePermission === "function",
            "stub must expose grantFeaturePermission recorder");
        // Test-only persist hook bypasses pyext.write_wallpaper_config so
        // we don't need to stub a full FileHelper round-trip here.
        let persisted = null;
        web._persistDecisionForTest = function(wid, key, value) {
            persisted = { wid: wid, key: key, value: value };
        };
        background.workshopid = "sec-web2-allow";
        web.pyext = _makeFakePyext({});
        web._lastPermissionDialog = null;
        const before = wev.grantPermissionCount;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 1);
        verify(typeof web._lastPermissionDialog === "object" &&
               web._lastPermissionDialog !== null,
            "permissionDialog ref must be exposed to tests");
        web._lastPermissionDialog.allow();
        compare(wev.grantPermissionCount, before + 1);
        compare(wev.lastGrantArgs.allow, true);
        compare(wev.lastGrantArgs.feature, 1);
        verify(persisted !== null, "remembered allow must persist");
        compare(persisted.key, "1");
        compare(persisted.value, "allow");
    }

    function test_featurePermissionRequested_priorAllow_grantsSync_noDialog() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        background.workshopid = "sec-web2-cached-allow";
        web.pyext = _makeFakePyext({ permissions: { "1": "allow" } });
        web._lastPermissionDialog = null;
        web._persistDecisionForTest = null;
        const before = wev.grantPermissionCount;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 1);
        compare(wev.grantPermissionCount, before + 1);
        compare(wev.lastGrantArgs.allow, true);
        verify(web._lastPermissionDialog === null,
            "cached allow must not open the dialog");
    }

    function test_featurePermissionRequested_priorDeny_grantsFalse_noDialog() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        background.workshopid = "sec-web2-cached-deny";
        web.pyext = _makeFakePyext({ permissions: { "1": "deny" } });
        web._lastPermissionDialog = null;
        const before = wev.grantPermissionCount;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 1);
        compare(wev.grantPermissionCount, before + 1);
        compare(wev.lastGrantArgs.allow, false);
        verify(web._lastPermissionDialog === null,
            "cached deny must not open the dialog");
    }

    function test_micRequest_geolocationAllowedDoesNotShortCircuit() {
        // Per-feature decisions: geolocation cached as allow should NOT skip
        // the dialog for a mic request (MediaAudioCapture = 2).
        const wev = _findWebEngineView();
        verify(wev !== null);
        background.workshopid = "sec-web2-multi-feature";
        web.pyext = _makeFakePyext({ permissions: { "1": "allow" } });
        web._lastPermissionDialog = null;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 2);
        verify(web._lastPermissionDialog !== null,
            "feature without prior decision must open the dialog");
        // Resolve to avoid leaking the open dialog into the next test.
        web._lastPermissionDialog.deny();
    }

    function test_featurePermission_resetPath_reOpensDialog() {
        // After cached config is cleared, the next request must prompt again.
        const wev = _findWebEngineView();
        verify(wev !== null);
        background.workshopid = "sec-web2-reset";
        web.pyext = _makeFakePyext({ permissions: { "1": "allow" } });
        web._lastPermissionDialog = null;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 1);
        verify(web._lastPermissionDialog === null);
        // Swap to empty config (simulating resetWallpaperConfig).
        web.pyext = _makeFakePyext({});
        web._lastPermissionDialog = null;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 1);
        verify(web._lastPermissionDialog !== null,
            "reset path must re-prompt the user");
        web._lastPermissionDialog.deny();
    }

    function test_featurePermission_noPyext_deniesSafely() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        background.workshopid = "sec-web2-no-pyext";
        web.pyext = null;
        web._lastPermissionDialog = null;
        const before = wev.grantPermissionCount;
        wev.featurePermissionRequested("file:///tmp/fake_wallpaper.html", 1);
        compare(wev.grantPermissionCount, before + 1);
        compare(wev.lastGrantArgs.allow, false,
            "no pyext must deny safely");
    }

    // ── JS console + onerror bridge ─────────────────────────────────────────
    // The production handler forwards (level, msg, line, src) to QML console
    // with a [WEK-page LEVELTAG] prefix.  We assert against the
    // _lastConsoleForward seam on the outer webItem (production: null).
    function test_javaScriptConsoleMessage_routesToQmlConsoleByLevel() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        web._lastConsoleForward = null;
        wev.javaScriptConsoleMessage(0, "info hello", 12, "wp.js");
        verify(web._lastConsoleForward !== null);
        compare(web._lastConsoleForward.qmlLevel, "log");
        verify(web._lastConsoleForward.message.indexOf("[WEK-page INFO]") !== -1);
        verify(web._lastConsoleForward.message.indexOf("wp.js:12") !== -1);

        web._lastConsoleForward = null;
        wev.javaScriptConsoleMessage(1, "warn there", 45, "wp.js");
        compare(web._lastConsoleForward.qmlLevel, "warn");
        verify(web._lastConsoleForward.message.indexOf("[WEK-page WARN]") !== -1);

        web._lastConsoleForward = null;
        wev.javaScriptConsoleMessage(2, "boom", 78, "wp.js");
        compare(web._lastConsoleForward.qmlLevel, "error");
        verify(web._lastConsoleForward.message.indexOf("[WEK-page ERROR]") !== -1);
    }

    function test_javaScriptConsoleMessage_emptySourceID_usesInlineLabel() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        web._lastConsoleForward = null;
        wev.javaScriptConsoleMessage(0, "from inline", 3, "");
        verify(web._lastConsoleForward !== null);
        verify(web._lastConsoleForward.message.indexOf("<inline>:3") !== -1,
            "empty sourceID must surface as <inline>");
    }

    function test_pageError_routesThroughOnJavaScriptConsoleMessage_atLevelError() {
        // End-to-end: a level-2 console message (which the page-side
        // [WEK-page UNCAUGHT] shim emits) maps to the qml console.error path.
        // The handler wraps with its own [WEK-page ERROR] prefix; double
        // tagging is expected and harmless (the grep workflow still matches).
        const wev = _findWebEngineView();
        verify(wev !== null);
        web._lastConsoleForward = null;
        wev.javaScriptConsoleMessage(2,
            "[WEK-page UNCAUGHT] wp.js:42:7 ReferenceError: foo is not defined",
            42, "wp.js");
        verify(web._lastConsoleForward !== null);
        compare(web._lastConsoleForward.qmlLevel, "error");
        verify(web._lastConsoleForward.message.indexOf("[WEK-page ERROR]") !== -1);
        verify(web._lastConsoleForward.message.indexOf("UNCAUGHT") !== -1);
    }

    // ── pauseTimer onTriggered@242: grabToImage + lifecycle freeze ──────────
    function test_pauseTimerTriggered_freezesWebViewWhenPaused_constructs() {
        // Genuine "constructs / runs without throw" case.  The timer's
        // onTriggered calls web.grabToImage(cb) (QtWebView.qml:275) and
        // the freeze body inside cb early-returns when
        // `web.visible == false` (QtWebView.qml:277) — and a child Item
        // under a TestCase has effective visible=false because the
        // TestCase doesn't expose its window contents.  QML method
        // properties on the stub are read-only so we cannot install a
        // grabToImage recorder either.  Assert the structural contract
        // (300 ms interval, exists on the Backend.QtWebView) and that
        // firing triggered() after pause() executes without throwing.
        // (Coverage gap: stubbing grabToImage as a recordable signal
        // would let us assert the production scheduled exactly one
        // grab — see tests/qml/_stubs/QtWebEngine/WebEngineView.qml.)
        function findPauseTimer(parent) {
            const buckets = [parent.children || [], parent.data || []];
            for (const b of buckets) {
                for (let i = 0; i < b.length; i++) {
                    const t = b[i];
                    if (t && typeof t.start === "function" &&
                        typeof t.interval !== "undefined" &&
                        t.interval == 300) return t;
                }
            }
            return null;
        }
        const timer = findPauseTimer(web);
        verify(timer !== null);
        compare(timer.interval, 300);
        const wev = _findWebEngineView();
        verify(wev !== null);
        web.pause();             // sets web.paused = true
        compare(wev.paused, true);
        timer.triggered();       // exercises the freeze path
    }

    // ── longPauseTimer Frozen→Discarded escalation ──────────────────────────
    // Production stops at WebEngineView.LifecycleState.Frozen after 300 ms of
    // pause; the long-pause timer fires after 5 min and escalates to
    // Discarded, terminating the Chromium renderer and freeing the cached
    // pauseImage snapshot.  Tests reach the timer by id alias and trigger it
    // synchronously to avoid wall-clock waits.
    function _findLongPauseTimer() {
        // The long-pause Timer is a sibling of the existing pauseTimer (300ms);
        // distinguish by the much larger interval (the production default is
        // 5*60*1000 ms but tests may override it via longPauseMs).  Any Timer
        // with an interval > pauseTimer.interval and start/triggered methods
        // is the long-pause timer.
        const buckets = [web.children || [], web.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const t = b[i];
                if (t && typeof t.start === "function" &&
                    typeof t.triggered === "function" &&
                    typeof t.interval !== "undefined" &&
                    t.interval > 300) return t;
            }
        }
        return null;
    }

    function test_longPause_escalatesToDiscarded() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        const longTimer = _findLongPauseTimer();
        verify(longTimer !== null,
            "longPauseTimer must be declared adjacent to pauseTimer");
        // Reset state from any prior test.
        web._isDiscarded = false;
        wev.paused = true;        // longPauseTimer.onTriggered checks paused
        wev.lifecycleState = WebEngineView.Frozen;
        // Simulate the snapshot path having already populated pauseImage —
        // the long-pause escalation must clear it so the bytes get freed.
        const pauseImg = _findPauseImage();
        verify(pauseImg !== null);
        pauseImg.source = "file:///tmp/fake_snapshot.png";

        longTimer.triggered();

        compare(wev.lifecycleState, WebEngineView.Discarded,
            "long pause must escalate Frozen → Discarded");
        compare(pauseImg.source.toString(), "",
            "long pause must drop the snapshot to free its bytes");
        compare(web._isDiscarded, true,
            "long pause must flag _isDiscarded so resume reloads");
    }

    function test_resumeFromDiscarded_reloads() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        const longTimer = _findLongPauseTimer();
        verify(longTimer !== null);

        // First, escalate to Discarded via the timer.
        web._isDiscarded = false;
        wev.paused = true;
        longTimer.triggered();
        compare(web._isDiscarded, true);

        // Snapshot how many times loadWallpaper has fired so far, then resume.
        const before = web._testReloadCallCount;
        wev.paused = false;

        verify(web._testReloadCallCount > before,
            "resume from Discarded must trigger loadWallpaper()");
        compare(web._isDiscarded, false,
            "resume from Discarded must clear the flag");
    }

    // Rapid pause/resume must NOT escalate — the long-pause timer is stopped
    // before it fires, and _isDiscarded remains false so the resume path does
    // NOT trigger an unnecessary reload.
    function test_rapidPauseResume_doesNotEscalate() {
        const wev = _findWebEngineView();
        verify(wev !== null);
        const longTimer = _findLongPauseTimer();
        verify(longTimer !== null);

        web._isDiscarded = false;
        const reloadsBefore = web._testReloadCallCount;

        wev.paused = true;
        // No triggered() call — simulating the long-pause timer being stopped
        // before its interval elapses.  The resume path should take the
        // normal "thaw to Active" branch, not the discarded-reload branch.
        wev.paused = false;

        compare(web._isDiscarded, false,
            "rapid pause/resume must not flip _isDiscarded");
        compare(web._testReloadCallCount, reloadsBefore,
            "rapid pause/resume must not trigger a reload");
        compare(wev.lifecycleState, WebEngineView.Active,
            "rapid resume must restore Active lifecycle state");
        // Resumed-from-non-discarded path also flips pauseImage.visible = false.
        const pauseImg = _findPauseImage();
        verify(pauseImg !== null);
        compare(pauseImg.visible, false,
            "rapid resume must hide the pause snapshot");
    }

    // ── WebEngineProfile cache cap ──────────────────────────────────────────
    // The wallpaper profile must declare an explicit DiskHttpCache type and a
    // 50 MB max size so animated web wallpapers can't grow ~/.cache/wek-wallpaper/
    // toward Chromium's implicit "1% of disk free" cap over long sessions.
    // localStorage persistence (offTheRecord=false + storageName) is unaffected.
    function test_profileHasCacheCap() {
        verify(typeof web.wallpaperProfile !== "undefined",
            "QtWebView root must expose wallpaperProfile via property alias");
        compare(web.wallpaperProfile.httpCacheType,
                WebEngineProfile.DiskHttpCache,
                "wallpaperProfile must declare DiskHttpCache explicitly");
        compare(web.wallpaperProfile.httpCacheMaxSize,
                50 * 1024 * 1024,
                "wallpaperProfile must cap the on-disk HTTP cache at 50 MB");
    }

    // Pin the SafeWallpaperBridge contract: a direct JS-side write to
    // webobj.loaded (the failure mode pre-fix) MUST NOT change the bridge's
    // state. Demonstrates via QML — the truly end-to-end JS-over-QWebChannel
    // case would need a live QtWebEngine page; this asserts the read-only
    // Q_PROPERTY surface through QML which has the same write-rejection
    // semantics (the C++ Q_PROPERTY has no WRITE clause; the QML stub
    // mirrors that via `readonly property` aliased to a backing field).
    function test_webobjLoaded_jsWriteIsSilentlyDropped() {
        const webobj = _findWebobj();
        verify(webobj !== null);
        webobj.setLoaded(false);
        compare(webobj.loaded, false);
        // Try to assign directly — QML on a readonly property throws a
        // TypeError at runtime; the getter still returns false. Swallow
        // the exception so the test asserts state, not throw shape.
        try { webobj.loaded = true; } catch (e) {}
        compare(webobj.loaded, false,
                "JS-side write to read-only Q_PROPERTY must not change state");
        // Verify the official path still works.
        webobj.setLoaded(true);
        compare(webobj.loaded, true);
    }
}
