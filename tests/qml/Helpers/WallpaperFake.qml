// Test stand-in for Plasma's `wallpaper` context property. main.qml resolves its
// unqualified `wallpaper.*` references to the `id: wallpaper` ScreenRig gives this
// instance, via the Qt.createComponent creation-context chain (same mechanism
// production uses for Scene.qml -> `background`).
//
// `configuration` is a `var` (plain JS object), NOT a QtObject: QML forbids
// QML-declared property names beginning with an uppercase letter, but the real
// Plasma config keys (matching plugin/contents/config/main.xml) are PascalCase.
// A JS object permits uppercase keys. Reactivity is preserved at the whole-object
// level: reassigning `configuration` re-fires every `wallpaper.configuration.X`
// binding in main.qml (source->applySource, PerOptChanged, displayMode, ...). Use
// ScreenRig.setConfig(partial) to mutate (it reassigns); a direct single-key write
// is read-correct but does NOT notify. Defaults are "playable": MouseInput false
// (avoids the 2s hookTimer tree-dump), a known BackgroundColor, scene DisplayMode.
import QtQuick
Item {
    id: root

    // `wallpaper.parent.screenGeometry` is read by WindowModel; ScreenRig (this
    // item's visual parent) supplies it. `accentColor` makes
    // hasOwnProperty('accentColor') true so main.qml's onBackendFirstFrame path is
    // exercised; QML exposes the auto `accentColorChanged()` as invokable.
    property color accentColor: "transparent"

    property var configuration: ({
        "SteamLibraryPath":    "",
        "WallpaperWorkShopId": "",
        "WallpaperSource":     "",
        "BackgroundColor":     "#0a0a0a",
        "DisplayMode":         0,        // Common.DisplayMode.Aspect
        "PauseMode":           0,
        "PauseFilterByScreen": false,
        "PauseOnBatPower":     false,
        "PauseBatPercent":     0,
        "ScreenSaverPolicy":   1,        // Pause (default)
        "SortMode":            0,
        "FilterMode":          0,
        "VideoBackend":        0,
        "MuteAudio":           false,
        "RandomizeWallpaper":  false,
        "NoRandomWhilePaused": false,
        "MpvStats":            false,
        "MouseInput":          false,
        "AnimatedPreview":     false,
        "Fps":                 30,
        "SwitchTimer":         15,
        "ResumeTime":          1,
        "Volume":              50,
        "Speed":               1.0,
        "FilterStr":           "",
        "PerOptChanged":       0,
        "CustomConf":          "",
        "HdrOutput":           false,
        "PostProcessing":      "",
        "SystemAudioCapture":  false,
        "VideoFolderPath":     "",
        "ActivePlaylistId":    "",
        "CurrentItemIndex":    0,
        "PlaylistsReloadSeq":  0
    })
}
