import QtQuick
import com.github.captsilver.wallpaperEngineKde
import QtQuick.Window
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

WallpaperItem {
Rectangle {
    id: background
    anchors.fill: parent
    color: wallpaper.configuration.BackgroundColor
    
    property string steamlibrary: Qt.resolvedUrl(wallpaper.configuration.SteamLibraryPath).toString()
    property string source: Qt.resolvedUrl(wallpaper.configuration.WallpaperSource).toString()

    property string filterStr: wallpaper.configuration.FilterStr

    property int    videoBackend: wallpaper.configuration.VideoBackend
    property int    switchTimer: wallpaper.configuration.SwitchTimer
    property int    fps: wallpaper.configuration.Fps

    property bool   randomizeWallpaper: wallpaper.configuration.RandomizeWallpaper
    property bool   noRandomWhilePaused: wallpaper.configuration.NoRandomWhilePaused
    property bool   mouseInput: wallpaper.configuration.MouseInput
    property bool   animatedPreview: wallpaper.configuration.AnimatedPreview
    property bool   mpvStats: wallpaper.configuration.MpvStats

    property bool   pauseOnBatPower: wallpaper.configuration.PauseOnBatPower
    property int    pauseBatPercent: wallpaper.configuration.PauseBatPercent
    property bool   hdrOutput: wallpaper.configuration.HdrOutput
    property string postProcessing: wallpaper.configuration.PostProcessing
    property bool   systemAudioCapture: wallpaper.configuration.SystemAudioCapture

    
    property var curOpt: ({})
    property string workshopid: {
        const wid = wallpaper.configuration.WallpaperWorkShopId;
        pyext.read_wallpaper_config(wid).then((res) => this.curOpt = res);
        return wid;
    }
    function get_opt_value(key, def) {
        if(curOpt.hasOwnProperty(key))
            return curOpt[key];
        return def;
    }

    // Update all derived properties when curOpt changes
    onCurOptChanged: {
        displayMode = get_opt_value('display_mode', wallpaper.configuration.DisplayMode);
        mute = get_opt_value('mute_audio', wallpaper.configuration.MuteAudio);
        volume = get_opt_value('volume', wallpaper.configuration.Volume);
        speed = get_opt_value('speed', wallpaper.configuration.Speed);
        const userProps = curOpt['user_props'];
        userPropsJson = userProps ? JSON.stringify(userProps) : "";
    }

    property int    displayMode: get_opt_value('display_mode', wallpaper.configuration.DisplayMode)
    property bool   mute: get_opt_value('mute_audio', wallpaper.configuration.MuteAudio)
    property int    volume: get_opt_value('volume', wallpaper.configuration.Volume)
    property real   speed: get_opt_value('speed', wallpaper.configuration.Speed)
    // User properties for scene wallpapers (JSON string format)
    property string userPropsJson: ""

    // Reactive bindings for configuration changes
    Connections {
        target: wallpaper.configuration
        function onDisplayModeChanged() {
            background.displayMode = background.get_opt_value('display_mode', wallpaper.configuration.DisplayMode);
        }
        function onMuteAudioChanged() {
            background.mute = background.get_opt_value('mute_audio', wallpaper.configuration.MuteAudio);
        }
        function onVolumeChanged() {
            background.volume = background.get_opt_value('volume', wallpaper.configuration.Volume);
        }
        function onSpeedChanged() {
            background.speed = background.get_opt_value('speed', wallpaper.configuration.Speed);
        }
    }

    property int    perOptChanged: wallpaper.configuration.PerOptChanged
    onPerOptChangedChanged: {
        pyext.read_wallpaper_config(workshopid).then((res) => {
            this.curOpt = res;
        });
    }

    // auto pause
    property bool   ok: !windowModel.reqPause && !powerSource.reqPause

    // detect TTY switch and pause wallpaper(s)
    TTYSwitchMonitor {
        id: ttyMonitor
        onTtySwitch: {
            if (sleep) {
                console.log("Preparing for sleep (possibly a VT switch)");
                this.pause();
            } else {
                console.log("Waking up (VT switch back)");
                this.play();
            }
        }
    }

    property string nowBackend: ""

    property var mouseHooker
    property bool hasLib: Common.checklib_wallpaper(background)

    property var customConf: Common.loadCustomConf(wallpaper.configuration.CustomConf)

    property string wallpaperPath
    property string wallpaperType

    signal sig_backendFirstFrame(string backname)
    function onBackendFirstFrame(backname) {
        console.error(`backend ${backname} first frame`);
        if (wallpaper.hasOwnProperty('accentColor'))
            wallpaper.accentColorChanged();
    }

    Component.onDestruction: {
        if(mouseHooker) {
            mouseHooker.destroy();
        }
    }

    function applySource() {
        console.log("[WEK-DBG main.applySource]",
            "source:", source,
            "WallpaperWorkShopId:", wallpaper.configuration.WallpaperWorkShopId,
            "ActivePlaylistId:", (wallpaper.configuration.ActivePlaylistId || "<empty>"),
            "currentBackend:", nowBackend);
        // Ensure user props are loaded for the current wallpaper before loading backend.
        // When both WallpaperWorkShopId and WallpaperSource change simultaneously,
        // QML may evaluate source first, so workshopid/curOpt/userPropsJson could be stale.
        const wid = wallpaper.configuration.WallpaperWorkShopId;
        if (wid) {
            pyext.read_wallpaper_config(wid).then((res) => { curOpt = res; });
        }

        const { path, type } = Common.unpackWallpaperSource(source);
        const path_changed = background.wallpaperPath !== path;
        const type_changed = background.wallpaperType !== type;
        const is_infobackend = background.nowBackend === "InfoShow";

        if(type_changed) wallpaperType = type;
        if(path_changed) wallpaperPath = path;

        if(type_changed || is_infobackend || !source) {
            loadBackend();
        } else if(path_changed) {
            backendLoader.item.source = path;
        }

        sourceCallback();
    }

    function getWorkshopIDPath() {
        return Common.getWorkshopDir(this.steamlibrary) + `/${this.workshopid}`;
    }

    onMouseInputChanged: {
        if(this.mouseInput) {
            hookTimer.start();
        }
        else if(this.mouseHooker) {
            this.mouseHooker.target = null;
            this.mouseHooker.destroy();   // bug: was `.destroy;` — bare
                                          // identifier reference, no call,
                                          // so the hidden grabber Item
                                          // leaked every time Mouse Input
                                          // was toggled off mid-session.
            this.mouseHooker = null;
        }
    }

    Timer {
        id: hookTimer
        running: true
        repeat: false
        interval: 2000
        property int tryTimes: 0
        onTriggered: {
            tryTimes++;
            if(tryTimes >= 10 || !background.hasLib || !background.mouseInput) return;
            if(background.mouseHooker) return;
            background.hookMouse();
        }
        Component.onCompleted: {
            background.hookMouse.connect(background.hookMouseSlot);
        }
    }
    signal hookMouse
    function hookMouseSlot() {
        if(!background.doHookMouse()) {
            hookTimer.start();
        } else {
            hookTimer.tryTimes = 0;
        }
    }
    function doHookMouse() {
        if(background.Window) {
            let hookParent = null;
            // Plasma 5: MouseEventListener → QQuickGridView
            const screenArea = Common.findItem(Window.contentItem, "MouseEventListener");
            if(screenArea !== null) {
                hookParent = Common.findItem(screenArea, "QQuickGridView");
            }
            // Plasma 6: AppletsLayout (desktop widget/icon area)
            if(hookParent === null) {
                hookParent = Common.findItem(Window.contentItem, "AppletsLayout");
            }
            // Plasma 6 fallback: FolderViewDropArea
            if(hookParent === null) {
                hookParent = Common.findItem(Window.contentItem, "FolderViewDropArea");
            }
            if(hookParent === null) {
                if(hookTimer.tryTimes >= 9) {
                    const tree = Common.genItemListStr(Window.contentItem, "  ", function(item) {
                        return item.toString();
                    });
                    console.warn("[WEK] MouseHook: failed to find hook target. Item tree:\n" + tree);
                }
                return false;
            }
            console.warn("[WEK] MouseHook: found target " + hookParent);
            if(background.mouseHooker) background.mouseHooker.destroy();
            background.mouseHooker = Qt.createQmlObject(`import QtQuick 2.12;
                    import com.github.captsilver.wallpaperEngineKde 1.2
                    MouseGrabber {
                        z: -1
                        anchors.fill: parent
                    }
            `, hookParent);
            return true;
       }
       return false;
    }

    WindowModel {
        id: windowModel
        screenGeometry: wallpaper.parent.screenGeometry
        filterByScreen: wallpaper.configuration.PauseFilterByScreen
        modePlay: wallpaper.configuration.PauseMode
        resumeTime: wallpaper.configuration.ResumeTime
    }

    PowerSource {
        id: powerSource
        readonly property bool reqPause: {
            (background.pauseOnBatPower && (st_battery_state == 'NoCharge' || st_battery_state == 'Discharging')) ||
            (background.pauseBatPercent !== 0 && st_battery_has && st_battery_percent < background.pauseBatPercent)
        }
    }

    Pyext {
        id: pyext
    }
    WallpaperListModel {
        id: wpListModel
        // Load the model whenever any playlist is active OR the legacy
        // randomize toggle is on. Without this, custom playlists with
        // ActivePlaylistId set but RandomizeWallpaper=false leave the
        // model unloaded, so PlaylistController can't resolve workshop
        // IDs and the cycle bails after 8 consecutive skips.
        enabled: background.randomizeWallpaper
              || (wallpaper.configuration.ActivePlaylistId !== "")
        workshopDirs: Common.getProjectDirs(background.steamlibrary)
        globalConfigPath: Common.getGlobalConfigPath(background.steamlibrary)
        filterStr: background.filterStr
        initItemOp: (item) => {
            if(!background.customConf) return;
            item.favor = background.customConf.favor.has(item.workshopid);
        }
        readfile: pyext.readfile

        function changeWallpaper(index) {
            if(this.model.count === 0) return;
            const model = this.model.get(index);
            wallpaper.configuration.WallpaperWorkShopId = model.workshopid;
            wallpaper.configuration.WallpaperSource = Common.packWallpaperSource(model);
        }
    }
    PlaylistController {
        id: playlistController
        wpListModel: wpListModel
        videoListModel: null   // runtime wallpaper has no video list model
        common: Common
        noRandomWhilePaused: background.noRandomWhilePaused
        desktopOk: background.ok

        activePlaylistIdRead:    wallpaper.configuration.ActivePlaylistId
        currentItemIndexRead:    wallpaper.configuration.CurrentItemIndex
        randomizeWallpaperRead:  wallpaper.configuration.RandomizeWallpaper
        switchTimerRead:         wallpaper.configuration.SwitchTimer

        // Writes happen here so `wallpaper.configuration` is in lexical scope —
        // QML can resolve Q_PROPERTY assignments correctly.
        setActivePlaylistId: function(id) {
            console.log("[WEK-DBG runtime setActivePlaylistId]", id);
            wallpaper.configuration.ActivePlaylistId = id;
        }
        setCurrentItemIndex: function(idx) {
            console.log("[WEK-DBG runtime setCurrentItemIndex]", idx);
            wallpaper.configuration.CurrentItemIndex = idx;
        }
        setWallpaperFromItem: function(item) {
            console.log("[WEK-DBG runtime setWallpaperFromItem]",
                "wid:", item.workshopid);
            wallpaper.configuration.WallpaperWorkShopId = item.workshopid;
            wallpaper.configuration.WallpaperSource = Common.packWallpaperSource(item);
        }
    }

    // lauch pause time to avoid freezing
    Timer {
        id: lauchPauseTimer
        running: false
        repeat: false
        interval: 300
        onTriggered: {
            backendLoader.item.pause();
            playTimer.start();
        }
    }
    Timer{
        id: playTimer
        running: false
        repeat: false
        interval: 5000
        onTriggered: { background.autoPause(); }
    }
    // lauch pause end

    // As always autoplay for refresh lastframe, sourceChange need autoPause
    // need a time for delay, which is needed for refresh
    function sourceCallback() {
        sourcePauseTimer.start();   
    }
    Timer {
        id: sourcePauseTimer
        running: false
        repeat: false
        interval: 200
        onTriggered: background.autoPause();
    }
    // Loading affordance — until the backend Item is mounted the user
    // sees only `BackgroundColor` (default solid black). For the 2-10s
    // cold-start window that's a black void with no signal. Fade in a
    // small label only when the wait crosses 600ms so fast loads don't
    // flash a hint that immediately disappears. Hidden once the backend
    // is loaded OR when the InfoShow first-run hint is showing.
    Timer {
        id: loadingHintDelay
        interval: 600
        running: !backendLoader.item && background.source && background.nowBackend !== "InfoShow"
        repeat: false
    }
    Text {
        anchors.centerIn: parent
        visible: !backendLoader.item
              && !loadingHintDelay.running
              && background.source
              && background.nowBackend !== "InfoShow"
        text: "Loading wallpaper…"
        color: "#cccccc"
        font.pixelSize: 18
        opacity: 0.0
        Behavior on opacity { NumberAnimation { duration: 250 } }
        onVisibleChanged: opacity = visible ? 0.7 : 0.0
        Component.onCompleted: opacity = visible ? 0.7 : 0.0
    }

    // main
    Item {
        id: backendLoader
        anchors.fill: parent
        property var item: null

        // Fade between wallpapers instead of hard-cutting. A playlist tick
        // every 15 min looks brutal as a flash of background color; a
        // 250ms opacity fade reads as intentional. opacity is bound to a
        // simple flag the loader flips around the destroy+create dance.
        opacity: _fadeOpacity
        Behavior on opacity { NumberAnimation { duration: 250 } }
        property real _fadeOpacity: 1.0

        signal loaded

        Component.onCompleted: {
            if(background.hasLib) {
                this.loaded.connect(this.changeMouseTarget);
                background.mouseHookerChanged.connect(this.changeMouseTarget);
            }
        }
        Component.onDestruction: {
            if(this.item) this.item.destroy();
        }
        function load(url, properties) {
            const com = Qt.createComponent(url);
            if(com.status === Component.Ready) {
                // Fade out, then swap on the next event-loop turn so the
                // user sees a soft transition rather than the bg color
                // flashing through.
                backendLoader._fadeOpacity = 0.0;
                if(this.item) this.item.destroy(100);
                this.item = null;
                try {
                    this.item = com.createObject(this, properties);
                } catch(e) {
                    this.loadInfoShow(e);
                    backendLoader._fadeOpacity = 1.0;
                    return;
                }
                // Restore opacity after the new backend is mounted —
                // Behavior on opacity animates it back in.
                backendLoader._fadeOpacity = 1.0;
                this.loaded();
            } else if(com.status == Component.Error) {
                this.loadInfoShow(com.errorString());
            }
        }
        function loadInfoShow(info) {
            this.load("backend/InfoShow.qml", {
                wid: background.workshopid,
                type: background.wallpaperType,
                info: info
            });
        }
        function changeMouseTarget() {
           if(backendLoader.item && background.mouseHooker) {
                let re = backendLoader.item.getMouseTarget();
                if(!re)
                    re = null;
                background.mouseHooker.target = re;
           }
        }
    }

    function loadBackend() {
        let qmlsource = "";
        let properties = {};

    
        // check source — differentiate first-run (no Steam library picked
        // yet) from broken config (had a wallpaper, now invalid). First-
        // run users need a call-to-action, not a "config may be broken"
        // scare line.
        if(!background.source) {
            if (!wallpaper.configuration.SteamLibraryPath) {
                backendLoader.loadInfoShow(
                    "Open the wallpaper settings (right-click the desktop → "
                    + "Configure Desktop and Wallpaper… → Wallpapers tab → "
                    + "Library) to pick your Steam library folder, then "
                    + "choose a Wallpaper Engine wallpaper.");
            } else {
                backendLoader.loadInfoShow(
                    "No wallpaper selected. Open the wallpaper settings "
                    + "and pick one from the Wallpapers or Videos tab.");
            }
            return;
        }
        // choose backend
        switch (background.wallpaperType) {
            case 'video':
                if(background.videoBackend == Common.VideoBackend.Mpv && background.hasLib)
                    qmlsource = "backend/Mpv.qml";
                else qmlsource = "backend/QtMultimedia.qml";
                properties = {};
                break;
            case 'web':
                qmlsource = "backend/QtWebView.qml";
                properties = {readfile: pyext.readfile, qwebChannelJs: pyext.qwebChannelSource(), patchedHtml: pyext.patchedHtml};
                break;
            case 'scene':
                if(background.hasLib) {
                    qmlsource = "backend/Scene.qml";
                    properties = {"assets": Common.getAssetsPath(steamlibrary)};
                } else {
                    backendLoader.loadInfoShow("Plugin lib not found. To support scene, please compile and install it.");
                    return; 
                }
                break;
            default:
                backendLoader.loadInfoShow("Not supported wallpaper type");
                return; 
        }
        // Don't pass source as a constructor property — set it after load.
        // This ensures QML bindings (e.g. userProperties) are evaluated first,
        // so the C++ backend receives USER_PROPS before SOURCE/LOAD_SCENE.
        // Demoted from console.error — a successful backend load shouldn't
        // present as an error in journalctl filtering.
        console.log("load backend: "+qmlsource);
        backendLoader.load(qmlsource, properties);
        backendLoader.item.source = background.wallpaperPath;
        sourceCallback();
    }
   
    function autoPause() {
        background.ok
            ? backendLoader.item.play()
            : backendLoader.item.pause();
    }

    Component.onCompleted: {
        // catsout → captsilver one-shot migration. No-op when marker present
        // or no catsout config exists. Spawns wek-migrate-from-catsout via
        // QProcess::startDetached, which restarts plasmashell — so anything
        // we do after this call may not finish.
        MigrationHelper.runIfNeeded();

        // load first backend
        applySource();

        // background signal connect
        background.videoBackendChanged.connect(loadBackend);
        background.okChanged.connect(autoPause);
        background.sourceChanged.connect(applySource);

        lauchPauseTimer.start();
    }
}
}
