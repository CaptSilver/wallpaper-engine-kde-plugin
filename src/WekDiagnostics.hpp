#pragma once
#include <QObject>
#include <QString>

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
//   - Home path -> <HOME> across env + cfg before writing.
//   - cfg_* fields with paths (SteamLibraryPath, WallpaperSource,
//     VideoFolderPath) -> <REDACTED>.
//   - Only WEKDE_/QT_/KDE_/XDG_/MESA_/AMD_VULKAN_/NVIDIA_/VK_ env vars
//     are captured.
class WekDiagnostics : public QObject {
    Q_OBJECT
public:
    explicit WekDiagnostics(QObject* parent = nullptr);

    // Synchronous (~3-5 seconds total — journalctl tail is the slow part).
    // Returns the absolute path to the created bundle, or empty string on
    // failure (with lastError() populated).
    Q_INVOKABLE QString saveBundle();
    Q_INVOKABLE QString lastError() const { return m_lastError; }

    // Test hooks — exposed for tst_wekdiagnostics; not part of the
    // production QML API.
    QString collectPluginEnvForTest() { return collectPluginEnv(); }
    QString collectRedactedCfgForTest() { return collectRedactedCfg(); }
    QString collectGpuInfoForTest() { return collectGpuInfo(); }
    QString collectCacheManifestForTest() { return collectCacheManifest(); }
    QString collectPipelineDiagForTest() { return collectPipelineDiag(); }

private:
    QString collectJournal();
    QString collectGpuInfo();
    QString collectVulkanInfo();
    QString collectPluginEnv();
    QString collectRedactedCfg();
    QString collectCacheManifest();
    QString collectPluginVersion();
    QString collectPipelineDiag();
    bool    pack(const QString& outPath, const QMap<QString, QByteArray>& files);

    QString m_lastError;
};

} // namespace wekde
