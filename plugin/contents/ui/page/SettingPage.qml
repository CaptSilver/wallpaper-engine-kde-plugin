import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Controls.Material 2.5 as QSMat
import QtQuick.Layouts 1.5

import ".."
import "../components"
import "../js/utils.mjs" as Utils

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami 2.6 as Kirigami

Flickable {
    id: settingTab

    // Наследуем тему от родителя
    Kirigami.Theme.inherit: true

    property alias cfg_Fps: sliderFps.value
    property alias cfg_PresentMode: cbPresentMode.currentIndex
    property alias cfg_Volume: sliderVol.value
    property alias cfg_MpvStats: ckbox_mpvStats.checked
    property alias cfg_Speed: spin_speed.dValue
    property alias cfg_MuteAudio: ckbox_muteAudio.checked
    property alias cfg_MouseInput: ckbox_mouseInput.checked
    property alias cfg_AnimatedPreview: ckbox_animatedPreview.checked
    property alias cfg_ResumeTime: resumeSpin.value
    property alias cfg_SwitchTimer: randomSpin.value
    property alias cfg_RandomizeWallpaper: ckbox_randomizeWallpaper.checked
    property alias cfg_NoRandomWhilePaused: ckbox_noRandomWhilePaused.checked
    property alias cfg_PauseFilterByScreen: ckbox_pauseFilterByScreen.checked
    property alias cfg_PlaylistNotifyOnAdvance: ckbox_playlistNotify.checked
    property alias cfg_CacheQuotaMB: spin_cacheQuota.value

    property alias cfg_PauseOnBatPower: chkbox_pauseOnBatPower.checked
    property alias cfg_PauseBatPercent: spin_pauseBatPercent.value
    property alias cfg_ScreenSaverPolicy: cbScreenSaverPolicy.currentIndex
    property alias cfg_HdrOutput: ckbox_hdrOutput.checked
    property alias cfg_SystemAudioCapture: ckbox_systemAudioCapture.checked
    // Color drawn behind the wallpaper. Visible as letterbox/pillarbox
    // bars when display mode is "Keep Aspect Ratio" and the wallpaper
    // aspect doesn't match the screen aspect. Stored as a Qt color
    // string (named color or "#rrggbb"). Default matches main.xml.
    property string cfg_BackgroundColor: "black"


    Layout.fillWidth: true
    ScrollBar.vertical: ScrollBar { id: scrollbar }

    contentWidth: width - (scrollbar.visible ? scrollbar.width : 0)
    contentHeight: contentItem.childrenRect.height
    clip: true
    boundsBehavior: Flickable.OvershootBounds

    OptionGroup {
        header.visible: false
        anchors.left: parent.left
        anchors.right: parent.right


        OptionGroup {
            Layout.fillWidth: true
            header.text: i18nc("@title:group settings section common options", "Common Option")
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Kirigami.Theme.activeBackgroundColor

            OptionItem {
                text: i18nc("@label playback pause setting", "Pause")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/pause.svg'
                actor:  ComboBox {
                    id: pauseMode
                    model: [
                        {
                            text: i18nc("@item:inlistbox pause mode", "Focus or Maximized Window"),
                            value: Common.PauseMode.FocusOrMax
                        },
                        {
                            text: i18nc("@item:inlistbox pause mode", "Focus Window"),
                            value: Common.PauseMode.Focus
                        },
                        {
                            text: i18nc("@item:inlistbox pause mode", "Maximized Window"),
                            value: Common.PauseMode.Max
                        },
                        {
                            text: i18nc("@item:inlistbox pause mode", "FullScreen"),
                            value: Common.PauseMode.FullScreen
                        },
                        {
                            text: i18nc("@item:inlistbox pause mode", "Any Window"),
                            value: Common.PauseMode.Any
                        },
                        {
                            text: i18nc("@item:inlistbox pause mode", "Never"),
                            value: Common.PauseMode.Never
                        }
                    ]
                    textRole: "text"
                    onActivated: cfg_PauseMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_PauseMode)
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info pause mode help text", "Automatically pauses playback if any/focus/maximized window detected")
                        wrapMode: Text.Wrap
                    }
               }
            }
            OptionItem {
                text: i18nc("@label settings option", "Only check window on current screen")
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_pauseFilterByScreen
                }
            }
            OptionItem {
                text: i18nc("@label settings option", "Pause if PC is on battery power")
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: chkbox_pauseOnBatPower
                }
            }
            OptionItem {
                text: i18nc("@label settings option", "Pause if battery level is below")
                text_color: Kirigami.Theme.textColor
                actor: SpinBox {
                        id: spin_pauseBatPercent
                        from: 0
                        to: 100
                        stepSize: 1
                }
            }
            OptionItem {
                text: i18nc("@label settings option", "When screen is locked")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/pause.svg'
                actor: ComboBox {
                    id: cbScreenSaverPolicy
                    model: [
                        { text: i18nc("@item:inlistbox screensaver policy", "Keep running"),                              value: 0 },
                        { text: i18nc("@item:inlistbox screensaver policy", "Pause (recommended)"),                       value: 1 },
                        { text: i18nc("@item:inlistbox screensaver policy", "Load alternate wallpaper (coming soon)"),    value: 2, enabled: false },
                    ]
                    textRole: "text"
                    onActivated: cfg_ScreenSaverPolicy = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_ScreenSaverPolicy)
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info screensaver policy help text", "Lock-screen state is session-wide on Plasma; every screen pauses together. There is no per-screen lock policy.")
                        wrapMode: Text.Wrap
                    }
                }
            }
            OptionItem {
                text: i18nc("@label settings option", "Display")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/window.svg'
                actor: ComboBox {
                    id: displayMode
                    model: [
                        {
                            text: i18nc("@item:inlistbox display mode", "Keep Aspect Ratio"),
                            value: Common.DisplayMode.Aspect
                        },
                        {
                            text: i18nc("@item:inlistbox display mode", "Scale and Crop"),
                            value: Common.DisplayMode.Crop
                        },
                        {
                            text: i18nc("@item:inlistbox display mode", "Scale to Fill"),
                            value: Common.DisplayMode.Scale
                        },
                    ]
                    textRole: "text"
                    onActivated: cfg_DisplayMode = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_DisplayMode)
                }
            }

            OptionItem {
                // Only meaningful in Keep Aspect Ratio mode — Crop/Scale fill
                // the screen edge-to-edge so the backdrop is never visible.
                visible: cfg_DisplayMode == Common.DisplayMode.Aspect
                text: i18nc("@label settings option", "Background Color")
                text_color: Kirigami.Theme.textColor
                actor: RowLayout {
                    spacing: 8
                    ColorButton {
                        id: bgColorBtn
                        def_val: "black"
                        colorValue: cfg_BackgroundColor
                        onColorPicked: (value) => cfg_BackgroundColor = value.toString()
                    }
                    Button {
                        text: i18nc("@action:button reset background color", "Reset")
                        enabled: !Qt.colorEqual(cfg_BackgroundColor, "black")
                        onClicked: {
                            cfg_BackgroundColor = "black";
                            bgColorBtn.colorValue = "black";
                        }
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info background color help text", "Color drawn in the letterbox/pillarbox bars when the wallpaper's aspect ratio doesn't match the screen.")
                        wrapMode: Text.Wrap
                    }
                }
            }

            OptionItem {
                text: i18nc("@label settings option", "Resume Time")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/timer.svg'
                actor: RowLayout {
                    spacing: 0
                    RowLayout {
                        SpinBox {
                            id: resumeSpin
                            from: 1
                            to: 60*1000
                            stepSize: 50
                        }
                        Label { text: i18nc("@label suffix milliseconds, with leading space", " ms"); color: Kirigami.Theme.textColor }
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info resume time help text", "Time to wait to resume playback from pause")
                    }
                }
            }
            OptionItem {
                text: i18nc("@label settings option", "Randomize Timer")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/time.svg'
                actor: Switch {
                    id: ckbox_randomizeWallpaper
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info randomize timer help text", "Equivalent to activating the built-in 'Filtered Library' playlist. Cycles through wallpapers passing the filter chips on the Wallpapers page.")
                        wrapMode: Text.Wrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_randomizeWallpaper.checked
                        Label {
                            id:heightpicker
                            text: i18nc("@label prefix for randomize-every spinner, with trailing space", "Randomize every ")
                            color: Kirigami.Theme.textColor
                        }
                        SpinBox {
                            id: randomSpin
                            width: font.pixelSize * 4
                            from: 1
                            to: 60*24*30
                            stepSize: 1
                        }
                        Label { text: i18nc("@label suffix minutes, with leading space", " min"); color: Kirigami.Theme.textColor }
                        Item { Layout.fillWidth: true }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: ckbox_randomizeWallpaper.checked
                        Label {
                            id: randomWhilePausedSetter
                            text: i18nc("@label settings option", "Skip randomizing while wallpaper is paused  ")
                            color: Kirigami.Theme.textColor
                        }
                        Switch {
                            id: ckbox_noRandomWhilePaused
                        }
                    }
                }
            }

            OptionItem {
                text: i18nc("@label settings option", "Notify on playlist advance")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                actor: Switch {
                    id: ckbox_playlistNotify
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info playlist notify help text", "Show a tray notification when the playlist advances to a new wallpaper. Off by default — enable if you want to confirm which wallpaper just appeared.")
                        wrapMode: Text.Wrap
                    }
                }
            }

            OptionItem {
                text: i18nc("@label settings option", "Playback Speed")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/fast-forward.svg'
                actor: RowLayout {
                    DoubleSpinBox {
                        id: spin_speed
                        dFrom: 0.1
                        dTo: 16.0
                        dStepSize: 0.1
                    }
                }
            }


            OptionItem {
                text: i18nc("@label settings option", "Mute Audio")
                text_color: Kirigami.Theme.textColor
                icon: ckbox_muteAudio.checked
                    ? '../../images/volume-off.svg'
                    : '../../images/volume-up.svg'
                actor: Switch {
                    id: ckbox_muteAudio
                }
            }
            OptionItem {
                text: i18nc("@label settings option", "Volume")
                text_color: Kirigami.Theme.textColor
                visible: !cfg_MuteAudio
                actor: RowLayout {
                    Layout.preferredWidth: displayMode.width
                    Label {
                        Layout.preferredWidth: font.pixelSize * 2
                        text: sliderVol.value.toString()
                        color: Kirigami.Theme.textColor
                    }
                    Slider {
                        id: sliderVol
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 5.0
                        snapMode: Slider.SnapOnRelease
                    }
                }
            }

            OptionItem {
                text: i18nc("@label settings option", "System Audio Capture")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/volume-up.svg'
                actor: Switch {
                    id: ckbox_systemAudioCapture
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        text: i18nc("@info system audio capture help text", "When enabled, audio-reactive wallpapers respond to all system audio (music, videos, games). When disabled, only the wallpaper's own background music is used.")
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.WordWrap
                        font.italic: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            OptionItem {
                visible: libcheck.wallpaper
                text_color: Kirigami.Theme.textColor
                text: i18nc("@label settings option", "Mouse Input")
                icon: '../../images/mouse.svg'
                actor: Switch {
                    id: ckbox_mouseInput
                }
            }

            OptionItem {
                text_color: Kirigami.Theme.textColor
                text: i18nc("@label settings option", "Animated Preview")
                icon: '../../images/gif.svg'
                actor: Switch {
                    id: ckbox_animatedPreview
                }
                // Hint banner shown only when the desktop has system-wide
                // "Reduce animations" enabled AND the user still has
                // Animated Preview on.  We don't auto-flip the config —
                // less surprising to suggest the change than make it.
                // `hasOwnProperty` guard keeps the binding quiet on
                // Plasma 6.0/6.1 where `hasReducedAnimations` may not
                // exist yet.
                contentBottom: Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: Kirigami.Settings.hasOwnProperty('hasReducedAnimations')
                             && Kirigami.Settings.hasReducedAnimations
                             && cfg_AnimatedPreview
                    type: Kirigami.MessageType.Information
                    text: i18nc("@info reduced motion hint banner", "Reduced motion is enabled system-wide. Consider disabling Animated Preview for less motion in this plugin.")
                }
            }
       }

        OptionGroup {
            Layout.fillWidth: true

            header.text: i18nc("@title:group settings section video options", "Video Option")
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Kirigami.Theme.activeBackgroundColor

            OptionItem {
                text: i18nc("@label settings option", "Video Backend")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/plugin.svg'
                actor: ComboBox {
                    model: [
                        {
                            text: i18nc("@item:inlistbox video backend", "QtMultimedia"),
                            value: Common.VideoBackend.QtMultimedia,
                            enabled: true
                        },
                        {
                            text: i18nc("@item:inlistbox video backend", "Mpv"),
                            value: Common.VideoBackend.Mpv,
                            enabled: libcheck.wallpaper
                        }
                    ].filter(el => el.enabled)
                    textRole: "text"
                    onActivated: cfg_VideoBackend = Common.cbCurrentValue(this)
                    Component.onCompleted: currentIndex = Common.cbIndexOfValue(this, cfg_VideoBackend)
                }
            }

            OptionItem {
                text: i18nc("@label settings option", "Show Mpv Stats")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                visible: cfg_VideoBackend == Common.VideoBackend.Mpv
                actor: Switch {
                    id: ckbox_mpvStats
                }
            }
        }
        OptionGroup {
            Layout.fillWidth: true

            header.text: i18nc("@title:group settings section scene options", "Scene Option")
            header.text_color: Kirigami.Theme.textColor
            header.icon: '../../images/cheveron-down.svg'
            header.color: Kirigami.Theme.activeBackgroundColor
            visible: libcheck.wallpaper

            OptionItem {
                text: i18nc("@label settings option frames per second", "Fps")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/tuning.svg'
                actor: RowLayout {
                    Label {
                        Layout.preferredWidth: font.pixelSize * 2
                        text: sliderFps.value.toString()
                        color: Kirigami.Theme.textColor
                    }
                    Slider {
                        id: sliderFps
                        Layout.fillWidth: true
                        from: 5
                        to: 60
                        stepSize: 1.0
                        snapMode: Slider.SnapOnRelease
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info fps preset help text", "Low: 10, Medium: 15, High: 25, Ultra High: 30")
                    }
                }

            }
            OptionItem {
                text: i18nc("@label settings option swapchain present mode", "Present mode")
                text_color: Kirigami.Theme.textColor
                actor: ComboBox {
                    id: cbPresentMode
                    // Model indices match the PresentModePolicy enum values
                    // (Auto=0 ... Immediate=4), so cfg_PresentMode (aliased to
                    // currentIndex) maps directly to the policy without a value
                    // lookup table.  See src/Vulkan/include/Vulkan/Swapchain.hpp.
                    model: [
                        i18nc("@item present mode auto",         "Auto (recommended)"),
                        i18nc("@item present mode fifo",         "Strict vsync (FIFO)"),
                        i18nc("@item present mode fifo relaxed", "Relaxed vsync (FIFO_RELAXED)"),
                        i18nc("@item present mode mailbox",      "Unthrottled (MAILBOX)"),
                        i18nc("@item present mode immediate",    "Immediate (no vsync)"),
                    ]
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info present mode help text",
                            "Auto picks based on Fps vs the monitor's refresh rate. "
                            + "FIFO avoids tearing but may judder when Fps is below refresh. "
                            + "Relaxed vsync smooths sub-refresh Fps. MAILBOX delivers the "
                            + "latest frame (low latency, may waste GPU/battery). "
                            + "Immediate disables vsync.")
                        wrapMode: Text.Wrap
                    }
                }
            }
            OptionItem {
                text: i18nc("@label settings option HDR output", "HDR Output")
                text_color: Kirigami.Theme.textColor
                actor: Switch {
                    id: ckbox_hdrOutput
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        text: i18nc("@info HDR output help text", "Pass HDR colors to the compositor without tonemapping. Requires Plasma HDR support.")
                        wrapMode: Text.Wrap
                    }
                }
            }
            OptionItem {
                id: cacheQuotaItem
                text: i18nc("@label settings option cache disk quota", "Cache disk quota")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                actor: RowLayout {
                    Layout.fillWidth: true
                    SpinBox {
                        id: spin_cacheQuota
                        from: 0
                        to: 100000
                        stepSize: 100
                        // 0 displays "Unlimited" to match the label semantics.
                        textFromValue: function(value, locale) {
                            return value === 0 ? i18n("Unlimited") : value.toString();
                        }
                        valueFromText: function(text, locale) {
                            if (text === i18n("Unlimited")) return 0;
                            return parseInt(text) || 0;
                        }
                        ToolTip.visible: hovered
                        ToolTip.text: i18n("Cache quota in MB; 0 = unlimited. Renderer + thumbnail caches are auto-evicted LRU when this is exceeded.")
                    }
                    Button {
                        text: i18n("Run cache GC now")
                        enabled: plugin_info.cache_path
                        onClicked: {
                            if (! pyext) return;
                            pyext.enforce_cache_quota_force(
                                [Common.urlNative(plugin_info.cache_path)],
                                (cfg_CacheQuotaMB || 0) * 1024 * 1024);
                        }
                    }
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.Wrap
                        // Read via pyext.helper (Q_PROPERTY-backed bindable
                        // property on the underlying FileHelper) so the
                        // readout updates live without an explicit poll.
                        // Hides itself when no GC has run yet.
                        visible: pyext && pyext.helper && pyext.helper.lastGcBytesFreed > 0
                        text: pyext && pyext.helper
                              ? i18n("Last GC: %1 MB freed",
                                     (pyext.helper.lastGcBytesFreed / 1048576).toFixed(1))
                              : ""
                    }
                }
            }
            OptionItem {
                id: shaderCacheItem
                text: i18nc("@label settings option shader cache", "Shader cache")
                text_color: Kirigami.Theme.textColor
                icon: '../../images/information-outline.svg'
                // Bumped by the Clear action to force the cache-size Text
                // below to re-query after a successful wipe.
                property int _cacheRev: 0
                actor: Kirigami.ActionToolBar {
                    Layout.fillWidth: true
                    alignment: Qt.AlignRight
                    flat: false
                    actions: [
                        Kirigami.Action {
                            text: i18nc("@action:button show shader cache", "Show")
                            tooltip: i18nc("@info:tooltip show shader cache", "Show in file manager")
                            onTriggered: {
                                if(plugin_info.cache_path)
                                    Qt.openUrlExternally(plugin_info.cache_path);
                            }
                        },
                        Kirigami.Action {
                            text: i18nc("@action:button clear shader cache", "Clear")
                            tooltip: i18nc("@info:tooltip clear shader cache", "Delete cached compiled shaders")
                            enabled: plugin_info.cache_path
                            onTriggered: clearShaderCacheConfirm.open()
                        }
                    ]
                }
                contentBottom: ColumnLayout {
                    Text {
                        Layout.fillWidth: true
                        property string cache_path: Common.urlNative(plugin_info.cache_path)
                        // Re-read whenever shaderCacheItem._cacheRev bumps
                        // (Clear sets it after wiping the dir).
                        property int _rev: shaderCacheItem._cacheRev

                        color: Kirigami.Theme.disabledTextColor
                        text: plugin_info.cache_path
                        ? i18nc("@info shader cache path - size, %1=path, %2=size", "%1 - %2", cache_path, cache_size)
                        : i18nc("@info shader cache not available", "Not available")

                        property string cache_size: {
                            // Touch _rev so the binding re-evaluates.
                            void _rev;
                            if(pyext) {
                                pyext.get_dir_size(this.cache_path).then(res => {
                                    this.cache_size = Utils.prettyBytes(res);
                                }).catch(reason => console.error(reason));
                            }
                            return i18nc("@info shader cache size placeholder while loading", "? MB");
                        }
                    }
                }
            }
        }
    }

    // The dialog can't sit inside OptionGroup — that `content` list is
    // QQuickItem-only and a Dialog is a Popup — and it can't go in the
    // Flickable's default property either: Flickable parks non-Items in a
    // plain QObject child list that nothing can walk back out of. `resources`
    // keeps it a first-class child of this page.
    resources: [
        Dialog {
            id: clearShaderCacheConfirm
            objectName: "clearShaderCacheConfirm"
            title: i18nc("@title:window clear shader cache confirmation", "Clear shader cache")
            modal: true
            implicitWidth: Kirigami.Units.gridUnit * 22
            anchors.centerIn: Overlay.overlay
            contentItem: Label {
                text: i18nc("@info confirmation message for clearing shader cache", "Delete all cached compiled shaders? They will be regenerated on the next wallpaper load (first frame may be slower).")
                wrapMode: Text.WordWrap
            }
            standardButtons: Dialog.Yes | Dialog.No
            onOpened: {
                const noBtn = standardButton(Dialog.No);
                if (noBtn) noBtn.forceActiveFocus();
            }
            onAccepted: {
                if (!plugin_info.cache_path || !pyext) return;
                pyext.clear_cache(Common.urlNative(plugin_info.cache_path))
                    .then(ok => {
                        if (ok && typeof shaderCacheItem !== "undefined")
                            shaderCacheItem._cacheRev += 1;
                        else if (!ok)
                            console.warn("Shader cache clear failed — see plasmashell journal");
                    });
            }
        }
    ]
}

