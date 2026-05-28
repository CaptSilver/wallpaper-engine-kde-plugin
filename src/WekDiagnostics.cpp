#include "WekDiagnostics.hpp"
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMap>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QStandardPaths>

#ifndef WEK_VERSION
#define WEK_VERSION "unknown"
#endif

namespace wekde {

WekDiagnostics::WekDiagnostics(QObject* parent) : QObject(parent) {}

QString WekDiagnostics::saveBundle()
{
    const auto cacheRoot = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    QDir       dir(cacheRoot + QStringLiteral("/wallpaper-scene-renderer"));
    if (! dir.exists()) {
        if (! dir.mkpath(QStringLiteral("."))) {
            m_lastError =
                QStringLiteral("Failed to create cache dir: %1").arg(dir.absolutePath());
            return {};
        }
    }
    const auto ts =
        QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss"));
    const auto out = QStringLiteral("%1/diag-%2.tar.gz").arg(dir.absolutePath(), ts);

    QMap<QString, QByteArray> files;
    files[QStringLiteral("journal.txt")]             = collectJournal().toUtf8();
    files[QStringLiteral("gpu-info.txt")]            = collectGpuInfo().toUtf8();
    files[QStringLiteral("vulkan-info.txt")]         = collectVulkanInfo().toUtf8();
    files[QStringLiteral("plugin-env.txt")]          = collectPluginEnv().toUtf8();
    files[QStringLiteral("plugin-cfg-redacted.txt")] = collectRedactedCfg().toUtf8();
    files[QStringLiteral("cache-manifest.txt")]      = collectCacheManifest().toUtf8();
    files[QStringLiteral("plugin-version.txt")]      = collectPluginVersion().toUtf8();
    // Opt-in via WEKDE_PIPELINE_DIAG=1; otherwise the file is omitted.
    const auto pipelineDiag = collectPipelineDiag();
    if (! pipelineDiag.isEmpty()) {
        files[QStringLiteral("pipeline-diag.txt")] = pipelineDiag.toUtf8();
    }

    if (! pack(out, files)) {
        // m_lastError set by pack().
        return {};
    }
    m_lastError.clear();
    return out;
}

QString WekDiagnostics::collectJournal()
{
    QProcess p;
    p.start(QStringLiteral("journalctl"),
            {QStringLiteral("--user-unit"), QStringLiteral("plasma-plasmashell"),
             QStringLiteral("-n"), QStringLiteral("5000"), QStringLiteral("--no-pager")});
    if (! p.waitForFinished(3000)) {
        return QStringLiteral("journalctl timed out or unavailable.");
    }
    return QString::fromUtf8(p.readAllStandardOutput());
}

QString WekDiagnostics::collectGpuInfo()
{
    QProcess lspci;
    lspci.start(QStringLiteral("lspci"), {QStringLiteral("-k")});
    lspci.waitForFinished(1000);
    const auto lspciOut = QString::fromUtf8(lspci.readAllStandardOutput());

    QProcess lsmod;
    lsmod.start(QStringLiteral("lsmod"), {});
    lsmod.waitForFinished(1000);
    const auto lsmodOut = QString::fromUtf8(lsmod.readAllStandardOutput());

    QStringList out;
    out << QStringLiteral("=== lspci -k (VGA/3D entries) ===");
    QRegularExpression vgaRe(QStringLiteral("^.*(VGA|3D|Display|DRM).*$"),
                             QRegularExpression::MultilineOption);
    auto m = vgaRe.globalMatch(lspciOut);
    while (m.hasNext()) out << m.next().captured(0);

    out << QString() << QStringLiteral("=== lsmod (GPU modules) ===");
    QRegularExpression modRe(QStringLiteral("^(nvidia|nouveau|amdgpu|radeon|i915|xe)\\b.*$"),
                             QRegularExpression::MultilineOption);
    m = modRe.globalMatch(lsmodOut);
    while (m.hasNext()) out << m.next().captured(0);

    return out.join('\n');
}

QString WekDiagnostics::collectVulkanInfo()
{
    QProcess p;
    p.start(QStringLiteral("vulkaninfo"), {QStringLiteral("--summary")});
    if (! p.waitForFinished(2000)) {
        return QStringLiteral("vulkaninfo unavailable or timed out.");
    }
    return QString::fromUtf8(p.readAllStandardOutput()).left(20000); // 20KB cap
}

QString WekDiagnostics::collectPluginEnv()
{
    const QStringList prefixes = {
        QStringLiteral("WEKDE_"),  QStringLiteral("QT_"),
        QStringLiteral("KDE_"),    QStringLiteral("XDG_"),
        QStringLiteral("MESA_"),   QStringLiteral("AMD_VULKAN_"),
        QStringLiteral("NVIDIA_"), QStringLiteral("VK_"),
    };
    auto       env  = QProcessEnvironment::systemEnvironment();
    const auto home = QDir::homePath();
    QStringList wanted;
    for (const auto& key : env.keys()) {
        for (const auto& pfx : prefixes) {
            if (key.startsWith(pfx)) {
                auto v = env.value(key);
                // Redact home path to <HOME>.
                if (! home.isEmpty()) v.replace(home, QStringLiteral("<HOME>"));
                wanted << QStringLiteral("%1=%2").arg(key, v);
                break;
            }
        }
    }
    wanted.sort();
    return wanted.join('\n');
}

QString WekDiagnostics::collectRedactedCfg()
{
    const auto cfgPath =
        QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation)
        + QStringLiteral("/plasma-org.kde.plasma.desktop-appletsrc");
    QFile f(cfgPath);
    if (! f.open(QIODevice::ReadOnly)) {
        return QStringLiteral("Plasma config not readable at %1").arg(cfgPath);
    }
    const auto        contents = QString::fromUtf8(f.readAll());
    const QStringList lines    = contents.split('\n');

    QStringList       wanted;
    bool              inBlock    = false;
    const QStringList redactKeys = {
        QStringLiteral("SteamLibraryPath"),
        QStringLiteral("WallpaperSource"),
        QStringLiteral("VideoFolderPath"),
    };
    for (const auto& line : lines) {
        if (line.contains(QStringLiteral("captsilver.wallpaperEngineKde]"))) {
            inBlock = true;
            wanted << line;
            continue;
        }
        if (line.startsWith('[') && inBlock) inBlock = false;
        if (! inBlock) continue;

        auto redacted = line;
        for (const auto& key : redactKeys) {
            QRegularExpression re(QStringLiteral("^(%1=).*").arg(key));
            redacted.replace(re, QStringLiteral("\\1<REDACTED>"));
        }
        wanted << redacted;
    }
    return wanted.join('\n');
}

QString WekDiagnostics::collectCacheManifest()
{
    const auto cacheRoot =
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
        + QStringLiteral("/wallpaper-scene-renderer");
    QDir d(cacheRoot);
    if (! d.exists())
        return QStringLiteral("No renderer cache directory at %1").arg(cacheRoot);

    QStringList lines;
    const auto  entries =
        d.entryInfoList(QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
    for (const auto& fi : entries) {
        lines << QStringLiteral("%1\t%2 bytes\t%3")
                     .arg(fi.fileName())
                     .arg(fi.size())
                     .arg(fi.lastModified().toString(Qt::ISODate));
    }
    return lines.join('\n');
}

QString WekDiagnostics::collectPluginVersion()
{
    return QStringLiteral("plugin: %1\n").arg(QStringLiteral(WEK_VERSION));
    // Submodule HEAD: deferred — would require a configure_file generated
    // header with the submodule SHA baked in.
}

QString WekDiagnostics::collectPipelineDiag()
{
    // Opt-in via WEKDE_PIPELINE_DIAG=1.  Picks up the renderer's last
    // pipeline diagnostic dump if the user reproduced the issue with the
    // env var set; otherwise omitted from the bundle.
    if (qEnvironmentVariable("WEKDE_PIPELINE_DIAG").trimmed() != QLatin1String("1"))
        return {};
    const auto cacheRoot =
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
        + QStringLiteral("/wallpaper-scene-renderer/pipeline-diag.txt");
    QFile f(cacheRoot);
    if (! f.open(QIODevice::ReadOnly))
        return QStringLiteral("WEKDE_PIPELINE_DIAG=1 set but no pipeline-diag.txt at %1")
            .arg(cacheRoot);
    return QString::fromUtf8(f.readAll()).left(200000); // 200KB cap
}

bool WekDiagnostics::pack(const QString&                   outPath,
                          const QMap<QString, QByteArray>& files)
{
    const auto tempDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                         + QStringLiteral("/wek-diag-")
                         + QDateTime::currentDateTime().toString(QStringLiteral("hhmmss"));
    if (! QDir().mkpath(tempDir)) {
        m_lastError = QStringLiteral("Failed to create temp dir: %1").arg(tempDir);
        return false;
    }
    for (auto it = files.begin(); it != files.end(); ++it) {
        QFile staging(tempDir + '/' + it.key());
        if (! staging.open(QIODevice::WriteOnly)) {
            m_lastError =
                QStringLiteral("Failed to write staging file: %1").arg(staging.fileName());
            QDir(tempDir).removeRecursively();
            return false;
        }
        staging.write(it.value());
    }
    QProcess tar;
    tar.start(QStringLiteral("tar"),
              {QStringLiteral("-czf"), outPath, QStringLiteral("-C"), tempDir,
               QStringLiteral(".")});
    const bool ok = tar.waitForFinished(5000);
    QDir(tempDir).removeRecursively();
    if (! ok || tar.exitCode() != 0) {
        m_lastError = QStringLiteral("tar failed: exitCode=%1, stderr=%2")
                          .arg(tar.exitCode())
                          .arg(QString::fromUtf8(tar.readAllStandardError()));
        return false;
    }
    return true;
}

} // namespace wekde
