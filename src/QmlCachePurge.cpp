#include "QmlCachePurge.hpp"

#include <QCryptographicHash>
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

            // A valid mtime means Qt can (and does) validate this entry
            // correctly on its own; nothing for us to do.
            if (QFileInfo(sourcePath).lastModified().isValid()) continue;

            const QString cacheFile = cache.filePath(qmlCacheFileName(sourcePath));
            if (! QFileInfo::exists(cacheFile)) continue;

            if (QFile::remove(cacheFile)) {
                result.removed.append({ sourcePath, cacheFile });
            } else {
                result.failed.append({ sourcePath, cacheFile });
            }
        }
    }

    return result;
}

} // namespace wekde
