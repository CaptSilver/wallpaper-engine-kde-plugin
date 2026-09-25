#include "QmlCachePurge.hpp"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

namespace wekde
{

QString qmlCacheFileName(const QString& sourcePath) {
    const QByteArray hash =
        QCryptographicHash::hash(sourcePath.toUtf8(), QCryptographicHash::Sha1).toHex();
    // Same trick Qt uses: ask QFileInfo what suffix a "<source>c" sibling
    // would have, rather than hand-rolling qml->qmlc / js->jsc / mjs->mjsc.
    const QString suffix = QFileInfo(sourcePath + QLatin1Char('c')).completeSuffix();
    return QString::fromLatin1(hash) + QLatin1Char('.') + suffix;
}

QString qmlCacheDir() {
    const QByteArray envOverride = qgetenv("QML_DISK_CACHE_PATH");
    if (! envOverride.isEmpty()) return QString::fromLocal8Bit(envOverride);
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation) +
           QStringLiteral("/qmlcache/");
}

QStringList pluginQmlPackageDirs() {
    return QStandardPaths::locateAll(
        QStandardPaths::GenericDataLocation,
        QStringLiteral("plasma/wallpapers/com.github.captsilver.wallpaperEngineKde/contents"),
        QStandardPaths::LocateDirectory);
}

QmlCachePurgeResult purgeUnverifiableQmlCache(const QStringList& sourceDirs,
                                              const QString&     cacheDir) {
    QmlCachePurgeResult result;
    const QStringList   nameFilters { QStringLiteral("*.qml"),
                                      QStringLiteral("*.js"),
                                      QStringLiteral("*.mjs") };
    const QDir          cache(cacheDir);

    for (const QString& dir : sourceDirs) {
        QDirIterator it(dir, nameFilters, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString sourcePath = it.next();

            const QString cacheFile = cache.filePath(qmlCacheFileName(sourcePath));
            if (! QFileInfo::exists(cacheFile)) continue;

            // A valid source mtime that is not newer than the cache entry
            // means Qt can (and, on a well-behaved host, does) validate
            // this entry correctly on its own; nothing for us to do. An
            // invalid mtime (the ostree case) or a source that has moved
            // on since the entry was compiled both mean the opposite --
            // treat them the same way rather than trusting a comparison
            // Qt's own loader is supposed to make but this host might not.
            const QDateTime sourceMtime = QFileInfo(sourcePath).lastModified();
            if (sourceMtime.isValid() && sourceMtime <= QFileInfo(cacheFile).lastModified())
                continue;

            if (QFile::remove(cacheFile)) {
                result.removed.append({ sourcePath, cacheFile });
            } else {
                result.failed.append({ sourcePath, cacheFile });
            }
        }
    }

    return result;
}

QString staleMainQmlMessage(const QString& host) {
    if (host == QStringLiteral("plasmashell")) {
        return QStringLiteral(
            "wekde: main.qml's compiled QML cache was stale and has been purged, but this "
            "plasmashell session already loaded the old compiled copy -- restart plasmashell "
            "to pick up the fresh one (log out/in, or `systemctl --user restart "
            "plasma-plasmashell.service`)");
    }
    // main.qml only ever runs inside plasmashell. Every other host that
    // imports this plugin's QML package (systemsettings, kcmshell6, ...)
    // walked the same package directory and can purge an orphaned entry
    // for main.qml, but it never loaded main.qml itself -- so there is no
    // "already loaded copy" for it to reopen, and the message must not
    // claim there is.
    return QStringLiteral("wekde: an orphaned compiled QML cache entry for main.qml was "
                          "purged from ") +
           host + QStringLiteral("'s cache -- main.qml never runs there, so this needs no action");
}

} // namespace wekde
