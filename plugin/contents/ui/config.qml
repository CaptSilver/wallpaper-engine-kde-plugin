import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.5
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami 2.4 as Kirigami

import "page"

ColumnLayout {
    id: root
    spacing: 5

    // Устанавливаем тему для всех дочерних элементов
    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false

    // Required by Plasma 6
    property var configDialog
    property var wallpaperConfiguration

    property string cfg_SteamLibraryPath
    property string cfg_WallpaperWorkShopId
    property string cfg_WallpaperSource
    property string cfg_FilterStr
    property int    cfg_SortMode
    property string cfg_VideoFolderPath

    // Playlist state goes through wallpaperConfiguration directly (live)
    // rather than cfg_*. cfg_* writes for these new fields didn't enable
    // the Apply button in our testing — the field is recognized by
    // KConfigPropertyMap (defined in main.xml) but the cfg_ diff tracker
    // doesn't pick up programmatic writes for entries that haven't yet
    // been persisted to appletsrc. Direct wallpaperConfiguration writes
    // are LIVE: the runtime sees them immediately, no Apply needed for
    // activation. Reading uses bracket-notation-friendly bindings so
    // the dialog reflects the current state.
    readonly property string activePlaylistId: wallpaperConfiguration
        ? (wallpaperConfiguration["ActivePlaylistId"] || "") : ""
    readonly property int currentItemIndex: wallpaperConfiguration
        ? (wallpaperConfiguration["CurrentItemIndex"] || 0) : 0

    property alias  cfg_Fps:                 settingPage.cfg_Fps
    property alias  cfg_Volume:              settingPage.cfg_Volume
    property alias  cfg_MpvStats:            settingPage.cfg_MpvStats
    property alias  cfg_Speed:               settingPage.cfg_Speed
    property alias  cfg_MuteAudio:           settingPage.cfg_MuteAudio
    property alias  cfg_MouseInput:          settingPage.cfg_MouseInput
    property alias  cfg_AnimatedPreview:     settingPage.cfg_AnimatedPreview
    property alias  cfg_ResumeTime:          settingPage.cfg_ResumeTime
    property alias  cfg_SwitchTimer:         settingPage.cfg_SwitchTimer
    property alias  cfg_RandomizeWallpaper:  settingPage.cfg_RandomizeWallpaper
    property alias  cfg_NoRandomWhilePaused: settingPage.cfg_NoRandomWhilePaused
    property alias  cfg_PauseFilterByScreen: settingPage.cfg_PauseFilterByScreen
    property alias  cfg_PauseOnBatPower:     settingPage.cfg_PauseOnBatPower
    property alias  cfg_PauseBatPercent:     settingPage.cfg_PauseBatPercent
    property alias  cfg_HdrOutput:           settingPage.cfg_HdrOutput
    property alias  cfg_PostProcessing:      settingPage.cfg_PostProcessing
    property alias  cfg_SystemAudioCapture:  settingPage.cfg_SystemAudioCapture
    property alias  cfg_BackgroundColor:     settingPage.cfg_BackgroundColor
    property int    cfg_DisplayMode
    property int    cfg_PauseMode
    property int    cfg_VideoBackend

    property int    cfg_PerOptChanged: 0

    //property alias  cfg_UseMpv
    //property alias  cfg_FilterMode: wallpaperPage.cfg_FilterMode

    property string cfg_CustomConf
    property var customConf: {
        customConf = Common.loadCustomConf(cfg_CustomConf);
    }

    property var iconSizes: {
        if(PlasmaCore.Units) {
            iconSizes = PlasmaCore.Units.iconSizes;
        } else {
            iconSizes = {
                large: 48
            }
        }
    }
    // property var themeWidth: {
    //     if(PlasmaCore.Theme && PlasmaCore.Theme.mSize) {
    //         themeWidth = PlasmaCore.Theme.mSize(theme.defaultFont).width;
    //     } else if(theme) {
    //         themeWidth = theme.mSize(theme.defaultFont).width;
    //     } else {
    //         themeWidth = font.pixelSize;
    //     }
    // }

    property var libcheck: ({
        wallpaper: Common.checklib_wallpaper(root),
        qtwebchannel: Common.checklib_webchannel(root)
    })


                    
    property var plugin_info: {
        if(!libcheck.wallpaper) {
            plugin_info = {
                version: "-",
                cache_path: null
            }
        } else {
            plugin_info = Qt.createQmlObject(`
                import QtQuick 2.0;
                import com.github.captsilver.wallpaperEngineKde 1.2
                PluginInfo {}
            `, this);
        }
    }

    property var pyext: {
        // FileHelper-based Pyext (no Python/WebSocket dependency)
        pyext = Qt.createQmlObject(`
            import QtQuick 2.0;
            Pyext {}
        `, this);
    }

    function saveConfig() {
        const wcfg = root.wallpaperConfiguration;
        console.warn("[WEK-DBG config.saveConfig] BEFORE",
            "cfg_WallpaperSource:", cfg_WallpaperSource,
            "cfg_WallpaperWorkShopId:", cfg_WallpaperWorkShopId,
            "wcfg.WallpaperSource:", wcfg ? wcfg["WallpaperSource"] : "<no wcfg>",
            "wcfg.WallpaperWorkShopId:", wcfg ? wcfg["WallpaperWorkShopId"] : "<no wcfg>",
            "wcfg.ActivePlaylistId:", wcfg ? (wcfg["ActivePlaylistId"] || "<empty>") : "<no wcfg>");
        wallpaperPage.saveConfig();
    }

    onCfg_WallpaperSourceChanged: {
        console.warn("[WEK-DBG config] cfg_WallpaperSource changed →", cfg_WallpaperSource);
    }
    onCfg_WallpaperWorkShopIdChanged: {
        console.warn("[WEK-DBG config] cfg_WallpaperWorkShopId changed →", cfg_WallpaperWorkShopId);
    }

    WallpaperListModel {
        id: wpListModel
        workshopDirs: Common.getProjectDirs(cfg_SteamLibraryPath)
        globalConfigPath: Common.getGlobalConfigPath(cfg_SteamLibraryPath)
        filterStr: cfg_FilterStr
        sortMode: cfg_SortMode
        initItemOp: (item) => {
            if(!root.customConf) return;
            item.favor = root.customConf.favor.has(item.workshopid);
        }
        enabled: Boolean(cfg_SteamLibraryPath)
        readfile: pyext.readfile
    }

    PlaylistController {
        id: playlistController
        wpListModel: wpListModel
        videoListModel: videoPage.videoListModel
        common: Common

        activePlaylistIdRead:    root.activePlaylistId
        currentItemIndexRead:    root.currentItemIndex
        randomizeWallpaperRead:  root.cfg_RandomizeWallpaper
        switchTimerRead:         root.cfg_SwitchTimer

        // ActivePlaylistId / CurrentItemIndex: write directly to
        // wallpaperConfiguration so they propagate live to the runtime
        // instance and don't interfere with cfg_-vs-plasmoid Apply
        // tracking (cfg_ writes for these new fields didn't enable Apply
        // in testing — the cfg_ diff tracker seems to bind only for
        // entries that have been persisted at least once).
        // WallpaperWorkShopId / WallpaperSource: keep going through cfg_*
        // (legacy flow used by manual wallpaper picks; Apply commits).
        setActivePlaylistId: function(id) {
            console.warn("[WEK-DBG dialog setActivePlaylistId]", id);
            if (root.wallpaperConfiguration)
                root.wallpaperConfiguration["ActivePlaylistId"] = id;
        }
        setCurrentItemIndex: function(idx) {
            console.warn("[WEK-DBG dialog setCurrentItemIndex]", idx);
            if (root.wallpaperConfiguration)
                root.wallpaperConfiguration["CurrentItemIndex"] = idx;
        }
        // No-op: only the RUNTIME PlaylistController should change the
        // wallpaper. When the dialog's mgr.activate fires its first tick,
        // we used to write cfg_WallpaperSource here — but that silently
        // burned the user's "unsaved-change" budget: cfg_WallpaperSource
        // gets pinned to the cycled wallpaper, so when the user later
        // deactivates and picks a wallpaper that happens to match what's
        // already in cfg_ (or what the dialog snapshotted at open), Apply
        // sees zero diff and stays grayed. The runtime's live write to
        // `wallpaper.configuration.WallpaperSource` is what actually
        // changes the user's wallpaper; the dialog doesn't need to echo it.
        setWallpaperFromItem: function(item) {
            console.warn("[WEK-DBG dialog setWallpaperFromItem (no-op)]",
                "wid:", item.workshopid);
        }
    }

    Component.onDestruction: {
        if(this.pyext) this.pyext.destroy();
    }

    function saveCustomConf() {
        cfg_CustomConf = Common.prepareCustomConf(this.customConf);
    }


    // Content
    PlasmaComponents.TabBar {
        id: bar
        implicitWidth: font.pixelSize*8 * 5
        PlasmaComponents.TabButton {
            text: "Wallpapers"
        }
        PlasmaComponents.TabButton {
            text: "Videos"
        }
        PlasmaComponents.TabButton {
            text: "Playlists"
        }
        PlasmaComponents.TabButton {
            text: "Settings"
        }
        PlasmaComponents.TabButton {
            text: "About"
        }
    }

    StackLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: bar.currentIndex

        WallpaperPage {
            id: wallpaperPage
            playlistManager: playlistController.manager
            cfg_ActivePlaylistId: root.activePlaylistId
            cfg_CurrentItemIndex: root.currentItemIndex
        }

        VideoPage {
            id: videoPage
            cfg_VideoFolderPath: root.cfg_VideoFolderPath
            activeWorkshopId: root.cfg_WallpaperWorkShopId
            cachePath: root.plugin_info ? (root.plugin_info.cache_path || "") : ""
            pyext: root.pyext
            playlistManager: playlistController.manager
            onCfg_VideoFolderPathChanged: root.cfg_VideoFolderPath = videoPage.cfg_VideoFolderPath
            onCommitWallpaper: (item) => {
                root.cfg_WallpaperWorkShopId = item.workshopid;
                root.cfg_WallpaperSource = Common.packWallpaperSource(item);
            }
        }

        PlaylistsPage {
            id: playlistsPage
            manager: playlistController.manager
            wpListModel: wpListModel
            videoListModel: videoPage.videoListModel
            cfg_ActivePlaylistId: root.activePlaylistId
        }

        SettingPage {
            id: settingPage
        }

        AboutPage {}
    }
}
