import QtQuick
import com.github.captsilver.wallpaperEngineKde
import QtQuick.Window
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

WallpaperItem {
Rectangle {
    id: background
    anchors.fill: parent
    // Per-wallpaper Background Color override: the per-wallpaper value
    // (background_color in <id>.json) falling back to the global
    // cfg_BackgroundColor.  In Keep-Aspect-Ratio mode backend/Scene.qml
    // sizes the renderer to the wallpaper's native aspect so this color
    // shows through the letterbox bars instead of the renderer's own.
    color: background.backgroundColor
    
    property string steamlibrary: Qt.resolvedUrl(wallpaper.configuration.SteamLibraryPath).toString()
    property string source: Qt.resolvedUrl(wallpaper.configuration.WallpaperSource).toString()

    property string filterStr: wallpaper.configuration.FilterStr

    property int    videoBackend: wallpaper.configuration.VideoBackend
    property int    switchTimer: wallpaper.configuration.SwitchTimer
    property int    fps: wallpaper.configuration.Fps
    // Swapchain present-mode policy (0=Auto / 1=Fifo / 2=FifoRelaxed / 3=Mailbox / 4=Immediate).
    // Pumped to backend/Scene.qml -> SceneViewer.presentMode -> SceneWallpaper.
    property int    presentMode: wallpaper.configuration.PresentMode
    // Output refresh rate in Hz, sampled from Window.screen.refreshRate.  Auto
    // policy uses this against `fps` to pick MAILBOX / FIFO_RELAXED / FIFO.
    // Window.screen is null until the plasmoid is mapped; fall back to 60 then.
    property int    outputRefreshHz: Window.screen
                                     ? Math.round(Window.screen.refreshRate)
                                     : 60

    property bool   randomizeWallpaper: wallpaper.configuration.RandomizeWallpaper
    property bool   noRandomWhilePaused: wallpaper.configuration.NoRandomWhilePaused
    property bool   mouseInput: wallpaper.configuration.MouseInput
    property bool   animatedPreview: wallpaper.configuration.AnimatedPreview
    property bool   mpvStats: wallpaper.configuration.MpvStats

    property bool   pauseOnBatPower: wallpaper.configuration.PauseOnBatPower
    property int    pauseBatPercent: wallpaper.configuration.PauseBatPercent
    property bool   hdrOutput: wallpaper.configuration.HdrOutput
    property string postProcessing: get_opt_value('postprocessing', false) ? "ultra" : ""
    property bool   systemAudioCapture: wallpaper.configuration.SystemAudioCapture

    // Honour the desktop's "Reduce animations" accessibility pref. The
    // `hasOwnProperty` guard keeps the binding silent on Plasma 6.0/6.1
    // where `hasReducedAnimations` may not exist yet (KF6 floor is 6.0;
    // the property shipped later). Read once at construction; Kirigami
    // emits no setting-change signal so a static read is fine.
    readonly property bool reducedMotion: Kirigami.Settings.hasOwnProperty('hasReducedAnimations')
                                          ? Kirigami.Settings.hasReducedAnimations
                                          : false

    
    property var curOpt: ({})
    // workshopid is a pure value binding; the async per-wallpaper config read
    // lives in the onWorkshopidChanged handler below. Mixing the read into
    // the binding body made re-evaluation re-fire the read invisibly and the
    // dependency tracker only saw WallpaperWorkShopId — the side effect was
    // opaque to the next maintainer. Splitting it makes the data flow
    // explicit: re-eval ⇒ value change ⇒ handler ⇒ async read ⇒ curOpt.
    property string workshopid: wallpaper.configuration.WallpaperWorkShopId
    onWorkshopidChanged: {
        pyext.read_wallpaper_config(workshopid).then((res) => { curOpt = res; });
    }
    function get_opt_value(key, def) {
        if(curOpt.hasOwnProperty(key))
            return curOpt[key];
        return def;
    }

    // Update all derived properties when curOpt changes
    onCurOptChanged: {
        displayMode = get_opt_value('display_mode', wallpaper.configuration.DisplayMode);
        backgroundColor = get_opt_value('background_color', wallpaper.configuration.BackgroundColor);
        mute = get_opt_value('mute_audio', wallpaper.configuration.MuteAudio);
        volume = get_opt_value('volume', wallpaper.configuration.Volume);
        speed = get_opt_value('speed', wallpaper.configuration.Speed);
        const userProps = curOpt['user_props'];
        userPropsJson = userProps ? JSON.stringify(userProps) : "";
    }

    property int    displayMode: get_opt_value('display_mode', wallpaper.configuration.DisplayMode)
    property string backgroundColor: get_opt_value('background_color', wallpaper.configuration.BackgroundColor)
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
        function onBackgroundColorChanged() {
            background.backgroundColor = background.get_opt_value('background_color', wallpaper.configuration.BackgroundColor);
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
    // ScreenSaverPolicy: 0 = Keep running (renderer keeps drawing behind the
    // lock surface), 1 = Pause (default; renderer drops GPU draw to ~zero
    // until unlock). The lockMonitor.active gate only flips background.ok
    // when Policy=1, so Policy=0 leaves the chain unaffected.
    property bool   ok: !windowModel.reqPause && !powerSource.reqPause
                       && !(lockMonitor.active
                            && wallpaper.configuration.ScreenSaverPolicy === 1)

    // detect TTY switch and pause wallpaper(s)
    TTYSwitchMonitor {
        id: ttyMonitor
        // Pause/resume the active backend on VT switch or sleep.  `this` is the
        // TTYSwitchMonitor (no play/pause) — the wallpaper is backendLoader.item,
        // which can be null mid-load, so guard it.  (function form: Qt6 deprecates
        // injecting the `sleep` parameter into a bare `onTtySwitch:` handler.)
        function onTtySwitch(sleep) {
            if (sleep) {
                console.log("Preparing for sleep (possibly a VT switch)");
                if (backendLoader.item) backendLoader.item.pause();
            } else {
                console.log("Waking up (VT switch back)");
                if (backendLoader.item) backendLoader.item.play();
            }
        }
    }

    // Detect screen-lock / screensaver activation and pause renderer
    // (joins TTY switch / battery / window-focus pauses via the
    // background.ok boolean chain above). The monitor exposes
    // Q_PROPERTY bool active; the chain consumes it directly without a
    // parallel pause/play branch — the existing okChanged -> autoPause
    // wiring (further down in this file) handles the dispatch.
    ScreenSaverMonitor {
        id: lockMonitor
    }

    property string nowBackend: ""

    property var mouseHooker
    // Declarative MouseGrabber factory for doHookMouse. Using a Component (vs
    // Qt.createQmlObject with an inline source string) lets qmlcachegen
    // precompile the body and surfaces typos at parse time. The MouseGrabber
    // type is imported at file top (line 2).
    Component {
        id: mouseHookerComponent
        MouseGrabber {
            z: -1
            anchors.fill: parent
        }
    }
    property bool hasLib: Common.checklib_wallpaper(background)

    property var customConf: Common.loadCustomConf(wallpaper.configuration.CustomConf)

    property string wallpaperPath
    property string wallpaperType

    signal sig_backendFirstFrame(string backname)
    function onBackendFirstFrame(backname) {
        console.error(`backend ${backname} first frame`);
        if (wallpaper.hasOwnProperty('accentColor'))
            wallpaper.accentColorChanged();
        // Record the manifest timestamp we loaded so the "Updated" badge
        // clears for this wallpaper. workshopManifest may be empty (Steam
        // library not configured, malformed .acf) — record 0 in that case
        // so the badge stays gone if the user later mounts a manifest.
        const wid = background.workshopid;
        if (wid && wpListModel.workshopManifest) {
            const ts = wpListModel.workshopManifest[wid] || 0;
            if (ts > 0) pyext.record_seen_version(wid, ts);
        }
    }

    Component.onDestruction: {
        if(mouseHooker) {
            mouseHooker.destroy();
        }
    }

    function applySource() {
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
            background.mouseHooker = mouseHookerComponent.createObject(hookParent);
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
        readonly property bool reqPause:
            (background.pauseOnBatPower && (st_battery_state === 'NoCharge' || st_battery_state === 'Discharging')) ||
            (background.pauseBatPercent !== 0 && st_battery_has && st_battery_percent < background.pauseBatPercent)
    }

    Pyext {
        id: pyext
        // Seed every settings-driven readfile root. Re-binds whenever any
        // input expression changes (steamlibrary derivation, video folder)
        // — fileHelper.onSeedRootsChanged clears + re-adds.
        seedRoots: {
            var roots = [];
            if (background.steamlibrary)
                roots.push(Common.urlNative(background.steamlibrary));
            if (wallpaper.configuration.VideoFolderPath)
                roots.push(Common.urlNative(wallpaper.configuration.VideoFolderPath));
            return roots;
        }
    }
    // Runtime Videos-tab model.  Editor (config.qml) shares the dialog's
    // VideoListModel; the runtime side has no dialog so it owns its own.
    // Without this, a Videos-tab item in an active playlist resolves null
    // at runtime + the playlist auto-deactivates after 8 consecutive
    // skipCurrent() ticks.  We don't set cachePath — the thumbnail-gen
    // branch is dialog-only.
    VideoListModel {
        id: runtimeVideoListModel
        folderPath: wallpaper.configuration.VideoFolderPath
        pyext: pyext
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
        // Manifest + seen-versions powering the "Updated" badge. Populated
        // once in Component.onCompleted below — evaluated bindings on these
        // two functions caused a feedback loop where each re-evaluation
        // produced a fresh map object, flipping the model's identity and
        // re-triggering downstream bindings. record_seen_version after
        // first-frame mutates the on-disk store but NOT the in-memory
        // workshopManifest/seenVersions properties — the badge clearing
        // only matters once the user re-opens the picker, which
        // re-instantiates the model via the editor.
        workshopManifest: ({})
        seenVersions:     ({})
        Component.onCompleted: {
            if (background.steamlibrary) {
                workshopManifest = pyext.read_workshop_manifest(
                                       Common.urlNative(background.steamlibrary));
            }
            seenVersions = pyext.all_seen_versions();
        }
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
    // Notification + diagnostics helpers. Per-monitor dedup is handled at
    // the QML caller side via `Window.screen?.primary !== false`; without
    // the guard a multi-monitor user would see 1+N popups for the same
    // failure (the wallpaper plasmoid is per-screen).
    WekNotifier   { id: notifier }
    WekDiagnostics { id: diagnostics }

    // Headless control surface — D-Bus session bus.  First-plasmoid-wins
    // on multi-monitor; the second plasmoid logs "service already
    // registered" and goes silent.  See src/WekControl.{hpp,cpp} for the
    // C++ side.  setPlaylistController binds the route once both elements
    // are constructed.
    WekControl {
        id: dbusControl
        Component.onCompleted: dbusControl.setPlaylistController(playlistController)
    }

    PlaylistController {
        id: playlistController
        wpListModel: wpListModel
        videoListModel: runtimeVideoListModel
        common: Common
        noRandomWhilePaused: background.noRandomWhilePaused
        desktopOk: background.ok
        notifier: notifier
        notifyOnAdvance: wallpaper.configuration.PlaylistNotifyOnAdvance
        dbusControl: dbusControl

        // Runtime mgr owns the playback cycle. (editorMode defaults to false.)
        activePlaylistIdRead:      wallpaper.configuration.ActivePlaylistId
        currentItemIndexRead:      wallpaper.configuration.CurrentItemIndex
        randomizeWallpaperRead:    wallpaper.configuration.RandomizeWallpaper
        switchTimerRead:           wallpaper.configuration.SwitchTimer
        // Bumped by the dialog after every playlist CRUD. PlaylistController
        // watches this and calls mgr.reload() so dialog-side edits propagate
        // to the runtime mgr without a plasmashell restart.
        playlistsReloadSeqRead:    wallpaper.configuration.PlaylistsReloadSeq

        // Writes happen here so `wallpaper.configuration` is in lexical scope —
        // QML can resolve Q_PROPERTY assignments correctly.
        setActivePlaylistId: function(id) {
            wallpaper.configuration.ActivePlaylistId = id;
        }
        setCurrentItemIndex: function(idx) {
            wallpaper.configuration.CurrentItemIndex = idx;
        }
        setWallpaperFromItem: function(item) {
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
            if (backendLoader.item) backendLoader.item.pause();
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
        Behavior on opacity { NumberAnimation { duration: background.reducedMotion ? 0 : 250 } }
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
        // Gated to 0ms when the desktop has "Reduce animations" enabled
        // (then the swap is an instant cut — preferred over a fade for
        // a user who asked for less motion).
        opacity: _fadeOpacity
        Behavior on opacity { NumberAnimation { duration: background.reducedMotion ? 0 : 250 } }
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
            // Per-monitor dedup — only the primary screen fires notifications.
            // On multi-monitor the wallpaper plasmoid is per-screen; without
            // dedup the user sees 1+N popups for the same failure. `!== false`
            // (not `=== true`) lets undefined fall through as truthy → fire-
            // by-default on Plasma versions that don't expose primary.
            if (Window.screen?.primary !== false) {
                notifier.wallpaperLoadFailed(background.workshopid || "", info);
            }
            this.load("backend/InfoShow.qml", {
                wid: background.workshopid,
                type: background.wallpaperType,
                info: info
            });
            // The four-button recovery pane emits pickAnotherRequested when
            // the user clicks "Pick another wallpaper". We don't have a
            // direct opener for the Plasma wallpaper-config dialog from
            // here (it's owned by Plasma's containment menu), so fall back
            // to a clear log line — the dialog is one right-click away.
            // The Item is destroyed on the next backend swap, which tears
            // the connection down with it.
            if (this.item && typeof this.item.pickAnotherRequested !== "undefined") {
                this.item.pickAnotherRequested.connect(function() {
                    console.log("[WEK] Pick another wallpaper requested — "
                        + "right-click the desktop → Configure Desktop and "
                        + "Wallpaper… → Wallpapers tab.");
                });
            }
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
                    i18nc("@info:status recovery copy first-run missing steam library",
                          "Open the wallpaper settings (right-click the desktop → "
                          + "Configure Desktop and Wallpaper… → Wallpapers tab → "
                          + "Library) to pick your Steam library folder, then "
                          + "choose a Wallpaper Engine wallpaper."));
            } else {
                backendLoader.loadInfoShow(
                    i18nc("@info:status recovery copy no wallpaper selected",
                          "No wallpaper selected. Open the wallpaper settings "
                          + "and pick one from the Wallpapers or Videos tab."));
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
                properties = {readfile: pyext.readfile, qwebChannelJs: pyext.qwebChannelSource(), patchedHtml: pyext.patchedHtml, pyext: pyext};
                break;
            case 'scene':
                if(background.hasLib) {
                    qmlsource = "backend/Scene.qml";
                    properties = {"assets": Common.getAssetsPath(steamlibrary)};
                } else {
                    backendLoader.loadInfoShow(i18nc("@info:status recovery copy scene plugin lib missing",
                        "Plugin lib not found. To support scene, please compile and install it."));
                    return;
                }
                break;
            default:
                if (background.wallpaperType === "application") {
                    backendLoader.loadInfoShow(
                        i18nc("@info:status recovery copy application wallpaper unsupported",
                              "Application wallpapers ship a native Windows .exe "
                              + "host and cannot be rendered by this Linux plugin. "
                              + "Pick a Scene, Web, or Video wallpaper instead."));
                } else if (background.wallpaperType === "preset") {
                    backendLoader.loadInfoShow(
                        i18nc("@info:status recovery copy preset wallpaper not standalone",
                              "Preset wallpapers are configuration overlays on "
                              + "another workshop entry; they are not standalone. "
                              + "Open the Workshop page (button below) for the "
                              + "source wallpaper."));
                } else {
                    backendLoader.loadInfoShow(
                        i18nc("@info:status recovery copy unsupported wallpaper type, %1=type",
                              "Wallpaper type '%1' is not supported (recognized types: scene, web, video).",
                              background.wallpaperType));
                }
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
        if (! backendLoader.item) return;
        if (background.ok) backendLoader.item.play();
        else backendLoader.item.pause();
    }

    Component.onCompleted: {
        // catsout → captsilver one-shot migration. No-op when the marker is
        // present or no catsout config exists. Runs IN-PROCESS via KConfig
        // (no subprocess, no plasmashell restart) and returns normally, so it
        // is safe to run applySource() and the signal connects below after it.
        MigrationHelper.runIfNeeded();

        // One-shot seed of last_seen_version for every existing <id>.json
        // based on the current Steam manifest. Without this, the first
        // launch after the Updated-badge feature lands would mark every
        // configured wallpaper as updated (no last_seen_version => 0 < any
        // manifest timestamp). Idempotent via its own KConfig marker;
        // empty steamlibrary just sets the marker and returns.
        MigrationHelper.seedLastSeenVersions(Common.urlNative(background.steamlibrary));

        // Cache GC pass — best-effort, never blocks the desktop.
        //   1. Orphan-GC over video-thumbs cache: drop entries whose source
        //      .mp4 no longer resolves under the installed-wallpaper or
        //      video-folder roots. Sidecars (.meta) anchor each thumbnail to
        //      its source so we can do this safely; entries without a sidecar
        //      (pre-feature cache) are kept.
        //   2. LRU eviction across the renderer cache + video-thumbs to keep
        //      the on-disk footprint under cfg_CacheQuotaMB (default 500 MB).
        //      Throttled inside FileHelper to one run per minute so frequent
        //      wallpaper switches don't churn the disk.
        if (typeof plugin_info !== 'undefined' && plugin_info && plugin_info.cache_path) {
            const thumbDir = Common.urlNative(plugin_info.cache_path);
            const installed = Common.getProjectDirs(background.steamlibrary);
            const videoDirs = [];
            if (wallpaper.configuration.VideoFolderPath)
                videoDirs.push(Common.urlNative(wallpaper.configuration.VideoFolderPath));
            pyext.prune_orphan_thumbnails(thumbDir, installed, videoDirs);
            const quotaMB = wallpaper.configuration.CacheQuotaMB || 0;
            if (quotaMB > 0) {
                pyext.enforce_cache_quota([thumbDir], quotaMB * 1024 * 1024);
            }
        }

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
