import QtQuick 2.5
import QtWebEngine 1.10
import QtWebChannel 1.10
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

    // Load patched HTML when source changes (after scripts are ready)
    onSourceChanged: {
        if (web._scriptsReady)
            loadWallpaper();
    }

    function loadWallpaper() {
        var fileUrl = webItem.source.toString();
        if (!fileUrl) return;

        var filePath = Common.urlNative(fileUrl);
        var baseUrl = fileUrl.substring(0, fileUrl.lastIndexOf('/') + 1);

        // Read HTML and inject History API patch before Angular/etc scripts
        var html = webItem.patchedHtml(filePath);
        if (html && html.length > 0) {
            console.warn("[WEK] loadHtml baseUrl=" + baseUrl + " htmlLen=" + html.length);
            web.loadHtml(html, baseUrl);
        } else {
            // Fallback: load URL directly (non-HTML wallpapers, read errors)
            console.warn("[WEK] fallback direct url=" + fileUrl);
            web.url = webItem.source;
        }
    }

    property string userPropsJson: background.userPropsJson

    onUserPropsJsonChanged: {
        if (!webobj.loaded || !webobj.userProperties) return;
        if (!userPropsJson) return;
        try {
            var saved = JSON.parse(userPropsJson);
            // Build a delta object with only changed properties
            var delta = {};
            for (var key in saved) {
                if (webobj.userProperties.hasOwnProperty(key)) {
                    // Clone the property definition, update value
                    delta[key] = Object.assign({}, webobj.userProperties[key]);
                    delta[key].value = saved[key];
                    // Also update the stored base properties
                    webobj.userProperties[key].value = saved[key];
                }
            }
            if (Object.keys(delta).length > 0) {
                console.warn("[WEK] Sending updated user properties:", JSON.stringify(Object.keys(delta)));
                webobj.sigUserProperties(delta);
            }
        } catch(e) {
            console.warn("[WEK] Failed to parse userPropsJson:", e);
        }
    }

    onFpsChanged: {
        if(webobj.loaded) {
            webobj.generalProperties.fps = webItem.fps;
            webobj.sigGeneralProperties(webobj.generalProperties);
        }
    }

    Image {
        id: pauseImage
        anchors.fill: parent
        visible: true
        enabled: false
    }
    QtObject {
        id: webobj
        WebChannel.id: "wpeQml"
        signal sigGeneralProperties(var properties)
        signal sigUserProperties(var properties)
        signal sigAudio(var audioArray)
        property bool loaded: false
        property var userProperties
        property var generalProperties
        onLoadedChanged: {
            if(!webobj.generalProperties)
                webobj.generalProperties = {fps: 24};
            var wpDir = Common.urlNative(webItem.source.toString());
            wpDir = wpDir.substring(0, wpDir.lastIndexOf('/'));
            // Load user properties from project.json BEFORE signaling,
            // so the wallpaper has zone/property data when it initializes.
            readfile(wpDir + "/project.json").then(function(text) {
                const json = Utils.parseJson(text);
                webobj.userProperties = json.general.properties;
                // Apply any saved user property overrides
                if (webItem.userPropsJson) {
                    try {
                        var saved = JSON.parse(webItem.userPropsJson);
                        for (var key in saved) {
                            if (webobj.userProperties.hasOwnProperty(key))
                                webobj.userProperties[key].value = saved[key];
                        }
                    } catch(e) {}
                }
                console.warn("[WEK] project.json loaded, properties:", JSON.stringify(Object.keys(json.general.properties || {})));
                // Now signal both — properties first, then general
                webobj.sigUserProperties(webobj.userProperties);
                webobj.sigGeneralProperties(webobj.generalProperties);
            });
        }
    }
    WebChannel {
        id: channel
        registeredObjects: [webobj]
    }

    WebEngineView {
    //WebView {
        id: web
        anchors.fill: parent
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
            settings.allowGeolocationOnInsecureOrigins = true;
            _init = true;
        }


        //onContextMenuRequested: function(request) {
        //    request.accepted = true;
        //}
        onLoadingChanged: (loadingInfo) => {
            console.warn("[WEK] onLoadingChanged status=" + loadingInfo.status
                + " url=" + loadingInfo.url
                + " (Succeeded=" + WebEngineView.LoadSucceededStatus
                + " Failed=" + WebEngineView.LoadFailedStatus + ")");
            if (loadingInfo.status == WebEngineView.LoadFailedStatus) {
                console.warn("[WEK] LOAD FAILED: " + loadingInfo.errorString);
            }
            if(loadingInfo.status == WebEngineView.LoadSucceededStatus) {
                // check pause after load
                if(paused) {
                    webItem.play();
                    webItem.pause();
                }
                background.sig_backendFirstFrame('QtWebEngine');
            }
        }

        onPausedChanged: {
            if(paused) {
                pauseTimer.start();
            }
            else {
                web.visible = true;
                web.lifecycleState = WebEngineView.LifecycleState.Active;
                pauseImage.visible = false;
            }
        }

        Component.onCompleted: {
            console.warn("[WEK] WebEngineView.onCompleted");

            if (!webItem.qwebChannelJs || webItem.qwebChannelJs.length < 100)
                console.warn("[WEK] qwebchannel source missing or truncated (" + webItem.qwebChannelJs.length + " chars)");
            else
                console.warn("[WEK] qwebchannel source loaded (" + webItem.qwebChannelJs.length + " chars)");

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
                        console.warn('[WEK] Deferred script running, QWebChannel=' + typeof QWebChannel);
                        new QWebChannel(qt.webChannelTransport, function(channel) {
                            console.warn('[WEK] QWebChannel connected');
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
                            wpeQml.loaded = true;
                            console.warn('[WEK] wpeQml.loaded set to true');
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
