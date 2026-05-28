import QtQuick 2.5
import QtWebEngine 1.10
import QtWebChannel 1.10
import com.github.captsilver.wallpaperEngineKde 1.2
import ".."
import "../js/utils.mjs" as Utils

Item {
    id: webItem
    anchors.fill: parent
    property url source
    property bool hasLib: background.hasLib
    property int fps: background.fps
    property var readfile
    property var patchedHtml
    property string qwebChannelJs: ""
    // Injected by main.qml at load time; tests may override directly on
    // the QtWebView. permissionHandler.handle() reads webItem.pyext.
    property var pyext: null
    // Test seams: production is null. The permission flow exposes the
    // active dialog and a hook that bypasses pyext.write_wallpaper_config
    // so QML harnesses can drive Allow / Deny without a Pyext promise stub.
    // _lastConsoleForward captures the most recent JS console message the
    // onJavaScriptConsoleMessage handler forwarded (for E6 assertions).
    property var _lastPermissionDialog: null
    property var _persistDecisionForTest: null
    property var _lastConsoleForward: null
    // Expose the dedicated WebEngineProfile so QML tests can introspect the
    // cache configuration without walking the child object tree.
    property alias wallpaperProfile: wallpaperProfile

    // Long-pause escalation: after this many ms of sustained pause, the
    // WebEngineView is escalated from Frozen → Discarded.  Discarded
    // terminates the Chromium renderer process (~50 MB RSS reclaim) and we
    // drop the cached snapshot bytes (~32 MB at 4K) too.  On resume the
    // wallpaper is reloaded from URL; localStorage survives.  Tuneable so
    // tests can drive the path without wall-clock waits.
    property int longPauseMs: 5 * 60 * 1000
    // Flag flipped true by longPauseTimer.onTriggered and cleared by
    // onPausedChanged on resume; tells the resume path to reload rather than
    // simply thaw lifecycleState back to Active.
    property bool _isDiscarded: false
    // Test instrumentation — counts loadWallpaper() invocations so the
    // discarded-resume path can be observed without mocking the entire
    // function.  Read-only u32 in production; zero overhead.
    property int _testReloadCallCount: 0

    // Load patched HTML when source changes (after scripts are ready)
    onSourceChanged: {
        if (web._scriptsReady)
            loadWallpaper();
    }

    function loadWallpaper() {
        webItem._testReloadCallCount += 1;
        var fileUrl = webItem.source.toString();
        if (!fileUrl) return;

        var filePath = Common.urlNative(fileUrl);
        var baseUrl = fileUrl.substring(0, fileUrl.lastIndexOf('/') + 1);
        var baseDir = Common.urlNative(baseUrl); // strip file:// once

        // Scope subsequent file:// requests from the page to this wallpaper's
        // directory; without this, malicious wallpapers can fetch arbitrary
        // local files (e.g. /etc/passwd, ~/.ssh/id_rsa).
        wallpaperInterceptor.setWallpaperBaseDir(baseDir);

        // Read HTML and inject History API patch before Angular/etc scripts
        var html = webItem.patchedHtml(filePath);
        if (html && html.length > 0) {
            console.log("[WEK] loadHtml baseUrl=" + baseUrl + " htmlLen=" + html.length);
            web.loadHtml(html, baseUrl);
        } else {
            // Fallback: load URL directly (non-HTML wallpapers, read errors)
            console.log("[WEK] fallback direct url=" + fileUrl);
            web.url = webItem.source;
        }
    }

    property string userPropsJson: background.userPropsJson

    onUserPropsJsonChanged: {
        if (!webobj.loaded || !webobj.userProperties) return;
        if (!userPropsJson) return;
        try {
            var saved = JSON.parse(userPropsJson);
            // Build a delta object with only changed properties AND a fresh
            // userProperties snapshot to push back into the bridge (its
            // userProperties is READ-only from QML now — writes are silent).
            var delta = {};
            var fresh = JSON.parse(JSON.stringify(webobj.userProperties));
            for (var key in saved) {
                if (fresh.hasOwnProperty(key)) {
                    // Clone the property definition, update value
                    delta[key] = Object.assign({}, fresh[key]);
                    delta[key].value = saved[key];
                    fresh[key].value = saved[key];
                }
            }
            if (Object.keys(delta).length > 0) {
                console.log("[WEK] Sending updated user properties:", JSON.stringify(Object.keys(delta)));
                webobj.pushUserProperties(fresh);
                // pushUserProperties fires sigUserProperties(fresh) — but the
                // existing contract was to fire sigUserProperties(delta), not the
                // full map. Preserve that by firing the delta-flavoured signal
                // explicitly so wallpapers iterating the payload still see only
                // the changed keys.
                webobj.sigUserProperties(delta);
            }
        } catch(e) {
            console.warn("[WEK] Failed to parse userPropsJson:", e);
        }
    }

    onFpsChanged: {
        if (webobj.loaded) {
            var g = JSON.parse(JSON.stringify(webobj.generalProperties || {}));
            g.fps = webItem.fps;
            webobj.pushGeneralProperties(g);
            // pushGeneralProperties auto-fires sigGeneralProperties(g).
        }
    }

    Image {
        id: pauseImage
        anchors.fill: parent
        visible: true
        enabled: false
    }

    // Forwards system audio FFT spectrum into the wallpaper through
    // QWebChannel.  Active only while the global "System Audio Capture"
    // setting is on; audio-reactive wallpapers (Perfect Wallpaper, Colorful
    // Fluid, Module Visualizer …) register listeners via
    // wallpaperRegisterAudioListener() and receive a 128-element array
    // (64 left bands + 64 right bands).
    WebAudioBridge {
        id: audioBridge
        enabled: background.systemAudioCapture
        onAudioBuffer: function(samples) {
            if (webobj.loaded) webobj.sigAudio(samples);
        }
    }

    SafeWallpaperBridge {
        id: webobj
        WebChannel.id: "wpeQml"
        onLoadedChanged: {
            if (!loaded) return;  // only react to false->true (lifecycle thaws are silent)
            if (!webobj.generalProperties || Object.keys(webobj.generalProperties).length === 0)
                webobj.pushGeneralProperties({fps: 24});
            var wpDir = Common.urlNative(webItem.source.toString());
            wpDir = wpDir.substring(0, wpDir.lastIndexOf('/'));
            // Load user properties from project.json BEFORE signaling,
            // so the wallpaper has zone/property data when it initializes.
            readfile(wpDir + "/project.json").then(function(text) {
                const json = Utils.parseJson(text);
                var userProps = (json && json.general && json.general.properties) || {};
                // Apply any saved user property overrides
                if (webItem.userPropsJson) {
                    try {
                        var saved = JSON.parse(webItem.userPropsJson);
                        for (var key in saved) {
                            if (userProps.hasOwnProperty(key))
                                userProps[key].value = saved[key];
                        }
                    } catch(e) {}
                }
                console.log("[WEK] project.json loaded, properties:", JSON.stringify(Object.keys(userProps)));
                // pushUserProperties + pushGeneralProperties each fire their
                // matching sig* signal automatically — no explicit emit needed.
                webobj.pushUserProperties(userProps);
                webobj.pushGeneralProperties(webobj.generalProperties || {fps: 24});
            });
        }
    }
    WebChannel {
        id: channel
        registeredObjects: [webobj]
    }

    // Per-wallpaper file:// gate (SEC-WEB1 sandbox).  setWallpaperBaseDir
    // is called from loadWallpaper() before loadHtml; until then the gate
    // blocks all file:// requests (defensive default).
    WebUrlInterceptor {
        id: wallpaperInterceptor
    }

    // Dedicated profile so the interceptor is scoped per-wallpaper-view and
    // doesn't share storage with any other QtWebEngine consumer.
    // offTheRecord=false + a stable storageName lets clock/weather wallpapers
    // persist their localStorage across reloads.
    WebEngineProfile {
        id: wallpaperProfile
        urlRequestInterceptor: wallpaperInterceptor
        offTheRecord: false
        storageName: "wek-wallpaper"

        // Cap the HTTP cache so animated web wallpapers can't grow
        // ~/.cache/wek-wallpaper/Cache/ unboundedly across long-running
        // sessions.  50 MB is well above the working set of any single
        // wallpaper and lets Chromium's LRU evict stale assets cleanly.
        // localStorage (the load-bearing persistence requirement for
        // clock/weather wallpapers) is unaffected by this cap.  Setting
        // httpCacheType explicitly guards against a Qt default flip in
        // a future LTS.
        httpCacheType:    WebEngineProfile.DiskHttpCache
        httpCacheMaxSize: 50 * 1024 * 1024
    }

    // Consents are persisted under the wallpaper config's `permissions` key
    // as { "<featureNum>": "allow" | "deny" }.  No prior decision → ask.
    QtObject {
        id: permissionHandler

        // Test seam (production: null) — see web._persistDecisionForTest.
        property var _persistDecisionForTest: null

        function handle(view, origin, feature) {
            const px = webItem.pyext;
            const wid = background.workshopid;
            const key = String(feature);
            if (! px || ! px.read_wallpaper_config) {
                // Pyext not ready — safe default: deny.
                view.grantFeaturePermission(origin, feature, false);
                return;
            }
            px.read_wallpaper_config(wid).then(function(cfg) {
                const saved = (cfg && cfg.permissions) || {};
                if (saved[key] === "allow") {
                    view.grantFeaturePermission(origin, feature, true);
                    return;
                }
                if (saved[key] === "deny") {
                    view.grantFeaturePermission(origin, feature, false);
                    return;
                }
                // No prior decision — surface the dialog.
                permissionDialog.askFor(view, origin, feature,
                        function(allow, remember) {
                    view.grantFeaturePermission(origin, feature, allow);
                    console.log("[WEK] permission " + (allow ? "GRANTED" : "DENIED")
                        + " feature=" + feature + " origin=" + origin
                        + " wid=" + wid + " remember=" + remember);
                    if (remember) {
                        saved[key] = allow ? "allow" : "deny";
                        if (webItem._persistDecisionForTest) {
                            webItem._persistDecisionForTest(
                                wid, key, saved[key]);
                        } else {
                            px.write_wallpaper_config(wid,
                                { permissions: saved });
                        }
                    }
                });
                webItem._lastPermissionDialog = permissionDialog;
            });
        }
    }

    PermissionDialog {
        id: permissionDialog
    }

    WebEngineView {
    //WebView {
        id: web
        anchors.fill: parent
        profile: wallpaperProfile
        enabled: true
        audioMuted: background.mute
        activeFocusOnPress: false
        webChannel: channel

        property bool paused: false
        property bool _scriptsReady: false
        property bool _init: {
            settings.fullscreenSupportEnabled = true;
            settings.autoLoadIconsForPage = false;
            settings.printElementBackgrounds = false;
            settings.playbackRequiresUserGesture = false;
            settings.pdfViewerEnabled = false;
            settings.showScrollBars = false;

            settings.localContentCanAccessRemoteUrls = true;
            // Geolocation + other dangerous features are NOT auto-granted;
            // see onFeaturePermissionRequested + permissionHandler below.
            _init = true;
        }


        //onContextMenuRequested: function(request) {
        //    request.accepted = true;
        //}
        // Track whether the first page load succeeded — in-page nav
        // failures after that shouldn't kick the user to InfoShow.
        property bool _firstLoadOk: false

        onLoadingChanged: (loadingInfo) => {
            console.log("[WEK] onLoadingChanged status=" + loadingInfo.status
                + " url=" + loadingInfo.url
                + " (Succeeded=" + WebEngineView.LoadSucceededStatus
                + " Failed=" + WebEngineView.LoadFailedStatus + ")");
            if (loadingInfo.status == WebEngineView.LoadFailedStatus) {
                console.warn("[WEK] LOAD FAILED: " + loadingInfo.errorString);
                // Only surface as a wallpaper-load failure if the FIRST
                // top-level navigation never succeeded. Otherwise this is
                // an in-page nav failure (broken link inside the wallpaper)
                // and shouldn't yank the user to InfoShow.
                if (! web._firstLoadOk && webItem.parent
                    && typeof webItem.parent.loadInfoShow === "function") {
                    webItem.parent.loadInfoShow(
                        "Web wallpaper failed to load: " + loadingInfo.errorString);
                }
            }
            if(loadingInfo.status == WebEngineView.LoadSucceededStatus) {
                web._firstLoadOk = true;
                // Fire the bridge's setLoaded(true) here — replaces the legacy
                // page-injected wpeQml.loaded = true writeback (which a malicious
                // wallpaper could re-trigger to re-fire the project.json load).
                // The bridge dedupes redundant true->true transitions and only
                // fires sigInit on the first one this lifetime, so in-page navs
                // that re-fire LoadSucceededStatus are harmless.
                if (webobj && typeof webobj.setLoaded === "function")
                    webobj.setLoaded(true);
                // check pause after load
                if(paused) {
                    webItem.play();
                    webItem.pause();
                }
                background.sig_backendFirstFrame('QtWebEngine');
            }
        }

        // Dangerous-feature consent (geolocation, microphone, camera, mouse
        // lock, desktop capture, notifications).  Per-(workshop-id, feature)
        // decisions are persisted via pyext.write_wallpaper_config; first
        // encounter opens permissionDialog. Test seams (_lastPermissionDialog,
        // _persistDecisionForTest, pyext) live on the outer webItem.
        onFeaturePermissionRequested: function(securityOrigin, feature) {
            permissionHandler.handle(web, securityOrigin, feature);
        }

        // JS console + parse-error bridge so silent black-screen wallpapers
        // can be diagnosed via:
        //   journalctl /usr/bin/plasmashell -f | grep "WEK-page"
        // Qt levels: 0=Info, 1=Warning, 2=Error.  The FileHelper-injected
        // window.addEventListener('error') shim emits via console.error so
        // uncaught throws land at level 2.
        onJavaScriptConsoleMessage: (level, message, lineNumber, sourceID) => {
            const levelTag = level === 2 ? "ERROR" : (level === 1 ? "WARN" : "INFO");
            const src      = sourceID && sourceID.length > 0 ? sourceID : "<inline>";
            const msg      = "[WEK-page " + levelTag + "] " + src + ":" + lineNumber
                           + " " + message;
            const qmlLevel = level === 2 ? "error" : (level === 1 ? "warn" : "log");
            if (level === 2)      console.error(msg);
            else if (level === 1) console.warn(msg);
            else                  console.log(msg);
            webItem._lastConsoleForward = {
                level: level, message: msg, lineNumber: lineNumber,
                sourceID: src, qmlLevel: qmlLevel,
            };
        }

        onPausedChanged: {
            if(paused) {
                pauseTimer.start();         // Frozen after 300 ms.
                longPauseTimer.start();     // Discarded after longPauseMs.
            }
            else {
                longPauseTimer.stop();
                if(webItem._isDiscarded) {
                    webItem._isDiscarded = false;
                    // Discarded discards page state; reload from URL.
                    // localStorage backing survives (the HTTP cache cap on
                    // the wallpaperProfile is independent).
                    web.visible = true;
                    pauseImage.visible = false;
                    webItem.loadWallpaper();
                }
                else {
                    web.visible = true;
                    web.lifecycleState = WebEngineView.LifecycleState.Active;
                    pauseImage.visible = false;
                }
            }
        }

        Component.onCompleted: {
            console.log("[WEK] WebEngineView.onCompleted");

            if (!webItem.qwebChannelJs || webItem.qwebChannelJs.length < 100)
                console.log("[WEK] qwebchannel source missing or truncated (" + webItem.qwebChannelJs.length + " chars)");
            else
                console.log("[WEK] qwebchannel source loaded (" + webItem.qwebChannelJs.length + " chars)");

            // Single Deferred script: Audio listener + QWebChannel + channel init
            // DocumentCreation injection doesn't work for dynamically inserted
            // sourceCode scripts on this Qt build, so everything goes in Deferred.
            userScripts.insert([
                {
                    worldId: WebEngineScript.MainWorld,
                    injectionPoint: WebEngineScript.Deferred,
                    name: "WallpaperEngineInit",
                    sourceCode: `
                        // Audio listener registration (available for wallpapers that
                        // call wallpaperRegisterAudioListener before QWebChannel connects)
                        window.wallpaperRegisterAudioListener = function(listener) {
                            if(window.wpeQml)
                                window.wpeQml.sigAudio.connect(listener);
                            else
                                window.wallpaperRAed = listener;
                        };
                    ` + webItem.qwebChannelJs + `
                        console.log('[WEK] Deferred script running, QWebChannel=' + typeof QWebChannel);
                        new QWebChannel(qt.webChannelTransport, function(channel) {
                            console.log('[WEK] QWebChannel connected');
                            window.wpeQml = channel.objects.wpeQml;
                            var wpeQml = window.wpeQml;
                            var propertyListener = window.wallpaperPropertyListener;
                            if(window.wallpaperRAed)
                                wpeQml.sigAudio.connect(window.wallpaperRAed);
                            if(propertyListener) {
                                if(propertyListener.applyGeneralProperties)
                                    wpeQml.sigGeneralProperties.connect(propertyListener.applyGeneralProperties);
                                if(propertyListener.applyUserProperties)
                                    wpeQml.sigUserProperties.connect(propertyListener.applyUserProperties);
                            }
                            // No more wpeQml.loaded = true — the QML side now drives
                            // init via setLoaded(true) on LoadSucceededStatus, fired
                            // from QtWebView.qml's onLoadingChanged handler. Wallpapers
                            // needing an "I'm ready" hook can connect to the bridge's
                            // sigInit signal.
                            console.log('[WEK] QWebChannel handshake complete');
                        });
                        document.getElementsByTagName('body')[0].ondragstart = function() { return false; }
                    `
                }
            ])

            // Scripts registered — now safe to load wallpaper
            web._scriptsReady = true;
            webItem.loadWallpaper();

            background.nowBackend = 'QtWebEngine';
        }

    }
    // There is no signal for frame complete, so use timer to make sure not black result
    Timer{
        id: pauseTimer
        running: false
        repeat: false
        interval: 300
        onTriggered: {
            // only check paused status on timer, not set
            // this is async
            web.grabToImage(function(result) {
                // check for paused again, make sure web is visible
                if(web.paused == false || web.visible == false) return;
                pauseImage.source = result.url;
                pauseImage.visible = true;
                web.visible = false;
                web.lifecycleState = WebEngineView.LifecycleState.Frozen;
            });
        }
    }
    // Long-pause escalation: when the wallpaper has been paused for
    // webItem.longPauseMs ms (default 5 min), terminate the Chromium
    // renderer (Discarded) and drop the cached snapshot.  Memory reclaim is
    // ~50 MB renderer RSS + ~32 MB snapshot bytes per wallpaper; on resume
    // we reload from URL and localStorage survives.
    Timer{
        id: longPauseTimer
        running: false
        repeat: false
        interval: webItem.longPauseMs
        onTriggered: {
            if(! web.paused) return;
            pauseImage.source = "";
            web.lifecycleState = WebEngineView.LifecycleState.Discarded;
            webItem._isDiscarded = true;
            console.log("[WEK] WebEngineView escalated to Discarded after long pause");
        }
    }
    Component.onCompleted: {
    //target: web.children[0] ? web.children[0] : null
    }

    function play(){
        web.paused = false;
    }
    function pause(){
        // Set status first
        web.paused = true;
    }
    function getMouseTarget() {
        web.activeFocusOnPress = true;
        return Qt.binding(function() { return web.children[0]; })
    }
}
