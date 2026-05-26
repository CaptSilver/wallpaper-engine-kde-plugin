import QtQuick
import QtTest

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
        webobj.loaded = false;
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
        webobj.loaded = false;
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
        webobj.loaded = false;
        try { bridge.audioBuffer([0, 1, 2, 3]); } catch (e) {}
        compare(relayed, 0,
                "audio relay must be gated on webobj.loaded");

        // Flip loaded → relay should now fire.
        webobj.loaded = true;
        try { bridge.audioBuffer([4, 5, 6, 7]); } catch (e) {}
        compare(relayed, 1,
                "loaded webobj must receive audio samples");

        webobj.sigAudio.disconnect(conn);
    }

    // ── webobj.onLoadedChanged@91: fired when webobj.loaded toggles true.
    //    The 26 LOC body reads project.json via readfile() and emits
    //    sigUserProperties + sigGeneralProperties on the webobj. ──────────
    function test_webobjLoaded_triggersUserPropertyLoad() {
        // webobj is a QtObject sibling of WebEngineView with a `loaded`
        // property and signals `sigUserProperties` + `sigGeneralProperties`.
        const webobj = _findWebobj();
        verify(webobj !== null);
        userPropsSpy.target    = webobj;
        generalPropsSpy.target = webobj;
        userPropsSpy.clear();
        generalPropsSpy.clear();
        const rfn = readfileCount;

        // Set webItem.userPropsJson so the inner overrides loop runs too.
        web.userPropsJson = '{"sliderProp":42}';
        webobj.loaded = true;

        // Production reads project.json then emits BOTH signals on the
        // webobj (QtWebView.qml:114-131). The test's readfile() invokes
        // the .then() callback synchronously, so by this point all three
        // observables must have advanced.
        compare(readfileCount, rfn + 1);
        verify(lastReadfileArg.indexOf("project.json") !== -1);
        compare(userPropsSpy.count, 1);
        compare(generalPropsSpy.count, 1);
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
}
