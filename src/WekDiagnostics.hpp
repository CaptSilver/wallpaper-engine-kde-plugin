#pragma once
#include <QObject>
#include <QString>
#include <QUrl>

namespace wekde
{

// Collects a support-bundle .tar.gz containing journal tail, GPU info,
// plugin env, redacted cfg_*, and the renderer cache manifest.
// User-triggered from the AboutPage "Save diagnostic bundle..." button.
// Output path is $XDG_CACHE_HOME/wallpaper-scene-renderer/diag-
// <timestamp>.tar.gz; the QML side opens a FileDialog to confirm /
// relocate it.
//
// Redaction:
//   - Home path -> <HOME> in every bundle file, applied once in saveBundle()
//     so a new collector cannot forget it.
//   - cfg_* fields with paths (SteamLibraryPath, WallpaperSource,
//     VideoFolderPath) -> <REDACTED>.
//   - Only WEKDE_/QT_/KDE_/XDG_/MESA_/AMD_VULKAN_/NVIDIA_/VK_ env vars
//     are captured.
class WekDiagnostics : public QObject {
    Q_OBJECT
public:
    explicit WekDiagnostics(QObject* parent = nullptr);
    ~WekDiagnostics() override;

    // Synchronous (~3-5 seconds total — journalctl tail is the slow part).
    // Returns the absolute path to the created bundle, or empty string on
    // failure (with lastError() populated).
    Q_INVOKABLE QString saveBundle();

    // Copies a bundle created by saveBundle() to the destination the user
    // picked in the save-as dialog. Returns false with lastError()
    // populated; clears lastError() on success.
    Q_INVOKABLE bool exportBundle(const QString& srcPath, const QUrl& dest);

    Q_INVOKABLE QString lastError() const { return m_lastError; }

    // Logs a pause-chain state change to the journal via qCInfo (unlike
    // QML's console.log/warn/error, which never reach journald in this
    // environment — see main.qml's pause-source wiring). One line per
    // source per transition: main.qml's onXChanged handlers only fire when
    // that source's own value actually changes, so this method does not
    // rate-limit on its own. `source` names which of the pause inputs
    // fired (windowModel, powerSource, screensaver, tty, userPause);
    // `playing` is that source's own resulting request, true for play,
    // false for pause.
    Q_INVOKABLE void logPauseTransition(const QString& source, bool playing);

    // Settings-page "Verbose logging" switch: turns the renderer's INFO log
    // lines on or off at runtime. The INFO gate is one flag per process but
    // each screen has its own instance, so the result is an OR across all
    // live instances' switches and the environment (WEKDE_LOG_INFO and
    // friends). An instance's vote is withdrawn when it is destroyed.
    Q_INVOKABLE void setVerboseLogging(bool enabled);

    // Test hooks — exposed for tst_wekdiagnostics; not part of the
    // production QML API.
    QString        collectPluginEnvForTest() { return collectPluginEnv(); }
    QString        collectRedactedCfgForTest() { return collectRedactedCfg(); }
    QString        collectGpuInfoForTest() { return collectGpuInfo(); }
    QString        collectCacheManifestForTest() { return collectCacheManifest(); }
    QString        collectPipelineDiagForTest() { return collectPipelineDiag(); }
    static QString scrubHomePathsForTest(const QString& text, const QString& homePath) {
        return scrubHomePaths(text, homePath);
    }

private:
    QString collectJournal();
    QString collectGpuInfo();
    QString collectVulkanInfo();
    QString collectPluginEnv();
    QString collectRedactedCfg();
    QString collectCacheManifest();
    QString collectPluginVersion();
    QString collectPipelineDiag();
    // Replaces the user's home path with <HOME>. Every collector's output
    // goes through this on its way into the bundle.
    static QString scrubHomePaths(const QString& text, const QString& homePath);
    bool           pack(const QString& outPath, const QMap<QString, QByteArray>& files);

    QString m_lastError;
    bool    m_verboseVote = false;
};

} // namespace wekde
