# QML test stubs — contract registry

Each row documents one stub's real-source path, behavioural contract, and
known shortcuts. When you add a new test that needs a stub method:

1. Find the real type in the "Real source" column.
2. Add the method with a signature MATCHING the real source (parameters
   included — see the drift log below for an example of why this matters).
3. Update the "Known shortcuts" cell if you bypass a real-world quirk.
4. Bump the "Last contract review" date in the stub file's header comment.

## com/github/captsilver/wallpaperEngineKde/

| Stub                | Real source                                | Contract                                                                                                              | Known shortcuts                                                                  |
|---------------------|--------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| FileHelper          | src/FileHelper.hpp + src/FileHelper.cpp    | Q_INVOKABLEs: readFile, patchedHtml, qwebChannelSource, getDirSize, requestDirSize, getFolderList, scanVideoFolder, readWallpaperConfig, writeWallpaperConfig, resetWallpaperConfig, readActiveBindings, generateThumbnail, clearCacheDir, addReadRoot, clearReadRoots. Signals: thumbnailReady(videoPath, outPath, ok), dirSizeReady(path, bytes). | Method bodies record call counts + last args; thumbnailReady/dirSizeReady fire synchronously via Qt.callLater. clearCacheDir always reports success (real impl gates on cache-root prefix). |
| MigrationHelperStub | src/MigrationHelper.cpp                    | Singleton; runIfNeeded() one-shot migration entrypoint.                                                               | No-op body — real migration is a v1.2 to v1.3 catsout-id rewrite via KConfig.    |
| MouseGrabber        | src/MouseGrabber.hpp + src/MouseGrabber.cpp| Property: target (QQuickItem*); functions: start(), stop().                                                           | No real mouse capture path — tests assign target directly.                       |
| MprisMonitor        | src/MprisMonitor.hpp + src/MprisMonitor.cpp| Properties: enabled, playing, title, artist, artUrl, dominantColor. Signals: propertiesChanged(title, artist, albumTitle, albumArtist, genres, duration); thumbnailChanged(hasThumbnail, colors); timelineChanged(position, duration, state); userShortcutRequested(name). Q_INVOKABLEs: invokeShortcut(name), engage(). | Drift: see drift log entry (stub's playbackStateChanged carries a string; real signal is int state).                  |
| Mpv                 | src/backend_mpv/                           | Properties: source, volume, mute. Functions: play, pause, stop, command(cmd), setProperty(name, val). Signals: firstFrame, sourceLoadFailed(reason). | source setter no-op; no real libmpv decoder.                                     |
| PlaylistManager     | src/PlaylistManager.hpp + src/PlaylistManager.cpp | Owns PlaylistsModel + PlaylistItemsModel; Q_INVOKABLE CRUD: createPlaylist, deletePlaylist, renamePlaylist, setMode, setIntervalMin, addItem, removeItem, moveItem, activate, deactivate, skipCurrent, acceptPick, pauseTicks, resumeTicks, setFilteredLibraryIntervalMin, reload, pickShuffle, playlistContains, itemsModel. Signals: tick, requestFilteredPick, activationFailed, persistFailed, persisted. | Models in-memory only; itemsModel returns a fresh empty ListModel each call. playlistContains always false. pickShuffleImpl is a deterministic round-robin (override on stub instance for fixed sequences). |
| PluginInfo          | src/PluginInfo.hpp + src/PluginInfo.cpp    | Properties: version, cache_path.                                                                                       | Synthetic test-stub version + empty cache_path by default.                       |
| SafeWallpaperBridge | src/SafeWallpaperBridge.hpp + src/SafeWallpaperBridge.cpp | READ-only properties: generalProperties, userProperties, loaded (mutation only via pushGeneralProperties / pushUserProperties / setLoaded). Signals: sigGeneralProperties, sigUserProperties, sigAudio, sigInit, generalPropertiesChanged, userPropertiesChanged, loadedChanged. | sigInit is one-shot via _initFired guard. Stub mirrors production READ-only QWebChannel posture. |
| SceneViewer         | src/plugin.cpp registers scenebackend::SceneObject (see src/backend_scene/qml_helper/) | Properties: source, assets, fps, speed, displayMode, fillMode (enum FillMode), userProperties, muted, volume, stats, mouseInput, hdrOutput, postprocessingOverride, systemAudioCapture, nativeAspectRatio. Functions: play, pause, setAcceptMouse, setAcceptHover. Signals: firstFrame, userShortcutRequested(name), mediaPlaybackChanged(state), mediaPropertiesChanged(title, artist, albumTitle, albumArtist, genres, duration), mediaThumbnailChanged(hasThumbnail, colors), mediaTimelineChanged(position, duration, state), mediaStatusChanged(enabled), videoDecodeFailed(summary). | No Vulkan / Quick3D — surface only.                                              |
| ScreenSaverMonitor  | src/ScreenSaverMonitor.hpp + src/ScreenSaverMonitor.cpp | Property: active (bool). Signal: screenSaverActiveChanged(active).                                                    | Tests poke active directly; binding chain handles the notify.                    |
| TTYSwitchMonitor    | src/TTYSwitchMonitor.hpp + src/TTYSwitchMonitor.cpp | Signal: ttySwitch(sleep: bool).                                                                                       | No D-Bus — tests emit the signal synthetically.                                  |
| WebAudioBridge      | src/WebAudioBridge.hpp + src/WebAudioBridge.cpp | Properties: enabled, intervalMs. Q_INVOKABLEs: feedTestPcm(samples, channels), runOneTick. Signal: audioBuffer(samples). | feedTestPcm returns false; runOneTick is a no-op.                                |
| WebUrlInterceptor   | src/WebUrlInterceptor.hpp + src/WebUrlInterceptor.cpp | Property: baseDir. Q_INVOKABLE: setWallpaperBaseDir(dir).                                                              | Records call counts + last baseDir; no actual interception path.                 |

## QtWebEngine/

| Stub             | Real source           | Contract                                                                                       | Known shortcuts                                                                        |
|------------------|-----------------------|------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| WebEngineProfile | Qt 6 QtWebEngine docs | Properties: urlRequestInterceptor, offTheRecord, storageName.                                  | Surface-only; no real Chromium request path.                                           |
| WebEngineScript  | Qt 6 QtWebEngine docs | Properties: sourceCode, sourceUrl, name, injectionPoint (enum), worldId (enum), runOnSubframes.| Enum types match Qt 6; values inert.                                                   |
| WebEngineView    | Qt 6 QtWebEngine docs | Properties: url, html, title, audioMuted, settings, profile, webChannel, userScripts, lifecycleState, activeFocusOnPress. Functions: loadHtml(html, baseUrl), reload, stop, runJavaScript(code, cb), grabToImage(cb), grantFeaturePermission(origin, feature, allow). Signals: loadingChanged(loadRequest), javaScriptConsoleMessage(level, message, lineNumber, sourceID), featurePermissionRequested(origin, feature). Enums: Feature, LoadStatus, LifecycleState. | runJavaScript callback fires synchronously with undefined; grabToImage callback fires synchronously with empty url. grantFeaturePermission records counts + last args. |

## QtMultimedia/

| Stub        | Real source           | Contract                                                                              | Known shortcuts                              |
|-------------|-----------------------|---------------------------------------------------------------------------------------|----------------------------------------------|
| AudioOutput | Qt 6 QtMultimedia docs| Properties: volume, muted.                                                            | No real audio device.                        |
| MediaPlayer | Qt 6 QtMultimedia docs| Properties: source, playbackRate, videoOutput, audioOutput, loops. Functions: play, pause, stop. Enum: Loops. | play / pause / stop are no-ops; no real decoder. |
| VideoOutput | Qt 6 QtMultimedia docs| Property: fillMode (enum FillMode).                                                   | Inherits Item; no actual video sink.         |

## org/kde/plasma/

| Stub            | Real source                         | Contract                                                                                   | Known shortcuts                                                                            |
|-----------------|-------------------------------------|--------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| DataSource      | plasma5support (Plasma 6 framework) | Properties: engine, connectedSources, sources, data. Functions: connectSource, disconnectSource. | data is an empty map by default so safe-fallback bindings (`data['Battery'] \|\| {}`) collapse. |
| SortFilterModel | plasma5support (Plasma 6 framework) | Properties: sourceModel, filterRole, filterRegExp, sortRole, sortOrder, count. Signal: dataChanged. | No actual filter / sort — properties are inert.                                            |
| WallpaperItem   | plasmoid (Plasma 6 framework)       | Headless Item stand-in for the Plasma WallpaperItem root type used by main.qml.            | Plain Item; no Plasma containment runtime.                                                 |

## org/kde/taskmanager/

| Stub               | Real source                          | Contract                                                                                                                                                                  | Known shortcuts                                                                                              |
|--------------------|--------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| AbstractTasksModel | libtaskmanager (Plasma framework)    | Singleton exposing the Role enum (AppName=257 ... IsWindow=268) + readonly camelCase aliases.                                                                             | Enum values match real numeric IDs so TasksModel.data() switch matches.                                      |
| ActivityInfo       | libtaskmanager (Plasma framework)    | Property: currentActivity (string).                                                                                                                                       | Empty string by default; tests assign directly.                                                              |
| TasksModel         | libtaskmanager (Plasma framework)    | Properties: count, filterByScreen, filterByActivity, activity, screenGeometry, virtualDesktop, sortMode, groupMode, filterByVirtualDesktop. Functions: makeModelIndex(i), data(idx, role). Signal: activeTaskChanged. Enums: SortOrder, GroupMode. | _windows array drives data() lookups by role-ID; activeTaskChanged is manually emitted by tests.             |
| VirtualDesktopInfo | libtaskmanager (Plasma framework)    | Property: currentDesktop.                                                                                                                                                 | Always 0; tests assign directly.                                                                             |

## Rules for stub authors

1. **Match the real signal signature** even if the test ignores the
   parameters. A previous QML test bug surfaced because a parameterless
   stub silently dropped a parameter that the production C++ signal
   carried; converting a stub from parameterless to parameterised forced
   the consumer wrapper to drop a JS `function(arg)` binding that was
   shadowing the property.
2. **Document shortcuts in the "Known shortcuts" cell** when you bypass a
   real-world quirk for test simplicity.
3. **Bump the "Last contract review" date** in the stub file's header
   comment when you touch the stub.
4. **Update this README in the same commit** that adds/modifies a stub.

## Drift log (audited 2026-05-27)

Drift items found during the initial audit. Each is recorded here so a
follow-up fix can address it without redoing the audit.

- **MprisMonitor.qml** — stub declares `signal playbackStateChanged(string state)`
  but the real C++ signal in `src/MprisMonitor.hpp` is
  `void playbackStateChanged(int state)` (0=stopped, 1=playing, 2=paused).
  Consumers that rely on the string form would break against the real
  signal; the stub should be migrated to `int state` so consumers exercise
  the same coercion behaviour they will see at runtime.

(No other drift surfaced during the audit pass — all other stub signals
and Q_PROPERTY surfaces line up with their real-source headers as of the
review date above.)

## Related helpers

See `tests/qml/Helpers/` for shared behavioural primitives — AsyncUtil
(microtask + tryCompare pumps), BackgroundFake, BackgroundStageFake,
ScreenRig, WallpaperFake. Stubs in this directory satisfy QML import
resolution; helpers in `Helpers/` provide reusable test scaffolding.
