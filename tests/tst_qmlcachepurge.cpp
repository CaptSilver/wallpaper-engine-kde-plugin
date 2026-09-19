// wekde::purgeUnverifiableQmlCache deletes QML disk-cache entries Qt itself
// can never re-validate. On an ostree host (Bazzite, Kinoite)
// every file under /usr carries mtime 0; QFileInfo::lastModified() comes
// back *invalid* for mtime 0 rather than the epoch, so Qt's own cache
// validation has nothing to compare a cached entry's stored timestamp
// against and just keeps trusting whatever is already on disk -- including
// an entry compiled from a source that has since changed underneath it.
// See src/QmlCachePurge.hpp for the full mechanism this relies on.

#include "QmlCachePurge.hpp"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTest>
#include <QTimeZone>

using wekde::purgeUnverifiableQmlCache;
using wekde::QmlCacheEntry;
using wekde::qmlCacheFileName;
using wekde::QmlCachePurgeResult;

namespace
{

// Writes a small fixture file at dir/relPath (creating parent directories
// as needed) and returns its absolute path.
QString writeFixture(const QDir& dir, const QString& relPath) {
    const QString absPath = dir.filePath(relPath);
    QDir().mkpath(QFileInfo(absPath).absolutePath());
    QFile f(absPath);
    if (! f.open(QIODevice::WriteOnly))
        qFatal("failed to create test fixture: %s", qPrintable(absPath));
    f.write("// fixture\n");
    f.close();
    return QFileInfo(absPath).absoluteFilePath();
}

// Rewrites path's modification time to the Unix epoch -- what every file
// under /usr carries on an ostree host.
bool stampEpoch(const QString& path) {
    QFile f(path);
    if (! f.open(QIODevice::ReadWrite)) return false;
    return f.setFileTime(QDateTime::fromMSecsSinceEpoch(0, QTimeZone::UTC),
                         QFileDevice::FileModificationTime);
}

// Drops a placeholder cache entry in cacheDir named exactly the way Qt
// would name one for sourcePath, and returns its path.
QString writeCacheEntry(const QDir& cacheDir, const QString& sourcePath) {
    QDir().mkpath(cacheDir.path());
    const QString cacheFile = cacheDir.filePath(qmlCacheFileName(sourcePath));
    QFile         f(cacheFile);
    if (! f.open(QIODevice::WriteOnly))
        qFatal("failed to create test cache entry: %s", qPrintable(cacheFile));
    f.write("compiled unit");
    f.close();
    return cacheFile;
}

// entries doesn't have to preserve QDirIterator's traversal order, so
// tests with more than one expected entry check membership rather than
// position.
bool containsEntry(const QList<QmlCacheEntry>& entries, const QString& sourcePath,
                   const QString& cacheFile) {
    for (const QmlCacheEntry& entry : entries) {
        if (entry.sourcePath == sourcePath && entry.cacheFile == cacheFile) return true;
    }
    return false;
}

} // namespace

class TestQmlCachePurge : public QObject {
    Q_OBJECT

private slots:
    // (a) A timestamp-less source with a matching cache entry: the entry
    // is removed, and the result names both the source and the cache file.
    // Also pins the Qt behaviour the whole mechanism depends on -- mtime 0
    // reads back as an *invalid* QDateTime, not the epoch.
    void timestamplessSource_withCacheEntry_isRemoved() {
        QTemporaryDir srcDir;
        QTemporaryDir cacheDir;
        QVERIFY(srcDir.isValid());
        QVERIFY(cacheDir.isValid());

        const QString source = writeFixture(QDir(srcDir.path()), "Foo.qml");
        QVERIFY(stampEpoch(source));
        QVERIFY2(! QFileInfo(source).lastModified().isValid(),
                 "mtime 0 must read back as an invalid QDateTime -- if this "
                 "fails, Qt's own semantics changed and the whole purge "
                 "rationale needs re-checking");

        const QString cacheFile = writeCacheEntry(QDir(cacheDir.path()), source);

        const QmlCachePurgeResult result =
            purgeUnverifiableQmlCache({ srcDir.path() }, cacheDir.path());

        QVERIFY(! QFileInfo::exists(cacheFile));
        QVERIFY(result.failed.isEmpty());
        QCOMPARE(result.removed.size(), 1);
        QCOMPARE(result.removed.first().sourcePath, source);
        QCOMPARE(result.removed.first().cacheFile, cacheFile);
    }

    // (b) A source with a real mtime is left alone -- Qt validates that one
    // correctly on its own, so purging it would just waste a recompile.
    void validMtimeSource_cacheEntryLeftAlone() {
        QTemporaryDir srcDir;
        QTemporaryDir cacheDir;
        QVERIFY(srcDir.isValid());
        QVERIFY(cacheDir.isValid());

        const QString source = writeFixture(QDir(srcDir.path()), "Foo.qml");
        QVERIFY(QFileInfo(source).lastModified().isValid());

        const QString cacheFile = writeCacheEntry(QDir(cacheDir.path()), source);

        const QmlCachePurgeResult result =
            purgeUnverifiableQmlCache({ srcDir.path() }, cacheDir.path());

        QVERIFY(QFileInfo::exists(cacheFile));
        QVERIFY(result.removed.isEmpty());
        QVERIFY(result.failed.isEmpty());
    }

    // (c) .js -> .jsc and .mjs -> .mjsc: Qt derives the cache suffix from
    // each source's own extension, not a single fixed one.
    void jsAndMjsSources_useTheirOwnCacheSuffix() {
        QTemporaryDir srcDir;
        QTemporaryDir cacheDir;
        QVERIFY(srcDir.isValid());
        QVERIFY(cacheDir.isValid());
        const QDir src(srcDir.path());
        const QDir cache(cacheDir.path());

        const QString jsSource = writeFixture(src, "script.js");
        QVERIFY(stampEpoch(jsSource));
        const QString jsCache = writeCacheEntry(cache, jsSource);
        QVERIFY(jsCache.endsWith(QStringLiteral(".jsc")));

        const QString mjsSource = writeFixture(src, "module.mjs");
        QVERIFY(stampEpoch(mjsSource));
        const QString mjsCache = writeCacheEntry(cache, mjsSource);
        QVERIFY(mjsCache.endsWith(QStringLiteral(".mjsc")));

        const QmlCachePurgeResult result =
            purgeUnverifiableQmlCache({ srcDir.path() }, cacheDir.path());

        QVERIFY(! QFileInfo::exists(jsCache));
        QVERIFY(! QFileInfo::exists(mjsCache));
        QCOMPARE(result.removed.size(), 2);
        QVERIFY(containsEntry(result.removed, jsSource, jsCache));
        QVERIFY(containsEntry(result.removed, mjsSource, mjsCache));
    }

    // (d) The walk recurses into subdirectories -- a plugin's QML package
    // is never flat (contents/ui/backend/... nests several levels deep).
    void nestedSource_isFound() {
        QTemporaryDir srcDir;
        QTemporaryDir cacheDir;
        QVERIFY(srcDir.isValid());
        QVERIFY(cacheDir.isValid());

        const QString source = writeFixture(QDir(srcDir.path()), "contents/ui/backend/Deep.qml");
        QVERIFY(stampEpoch(source));
        const QString cacheFile = writeCacheEntry(QDir(cacheDir.path()), source);

        const QmlCachePurgeResult result =
            purgeUnverifiableQmlCache({ srcDir.path() }, cacheDir.path());

        QVERIFY(! QFileInfo::exists(cacheFile));
        QCOMPARE(result.removed.size(), 1);
        QCOMPARE(result.removed.first().sourcePath, source);
        QCOMPARE(result.removed.first().cacheFile, cacheFile);
    }

    // (e) A timestamp-less source with no matching cache entry: there is
    // nothing to remove and nothing to report as failed -- a clean no-op,
    // not an error.
    void timestamplessSource_withoutCacheEntry_isNoOp() {
        QTemporaryDir srcDir;
        QTemporaryDir cacheDir;
        QVERIFY(srcDir.isValid());
        QVERIFY(cacheDir.isValid());

        const QString source = writeFixture(QDir(srcDir.path()), "Foo.qml");
        QVERIFY(stampEpoch(source));

        const QmlCachePurgeResult result =
            purgeUnverifiableQmlCache({ srcDir.path() }, cacheDir.path());

        QVERIFY(result.removed.isEmpty());
        QVERIFY(result.failed.isEmpty());
    }

    // (f) Unrelated files already sitting in the cache directory -- entries
    // for sources outside sourceDirs, or non-cache files entirely -- are
    // never touched.
    void unrelatedCacheFiles_areUntouched() {
        QTemporaryDir srcDir;
        QTemporaryDir cacheDir;
        QVERIFY(srcDir.isValid());
        QVERIFY(cacheDir.isValid());

        const QString source = writeFixture(QDir(srcDir.path()), "Foo.qml");
        QVERIFY(stampEpoch(source));
        writeCacheEntry(QDir(cacheDir.path()), source);

        const QString unrelated = QDir(cacheDir.path()).filePath("not-a-cache-entry.txt");
        QFile         f(unrelated);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("leave me alone");
        f.close();

        purgeUnverifiableQmlCache({ srcDir.path() }, cacheDir.path());

        QVERIFY(QFileInfo::exists(unrelated));
    }

    // (g) The cache file name for a known path, checked against a sha1
    // computed independently of this codebase (`printf '%s' <path> |
    // sha1sum`, run once by hand) -- not against QCryptographicHash calling
    // itself, which would only prove the implementation agrees with
    // itself, not with Qt.
    void cacheFileName_matchesIndependentlyComputedVector() {
        const QString path =
            QStringLiteral("/usr/share/plasma/wallpapers/com.github.captsilver.wallpaperEngineKde/"
                           "contents/ui/backend/"
                           "QtWebView.qml");

        // `printf '%s'
        // '/usr/share/plasma/wallpapers/com.github.captsilver.wallpaperEngineKde/contents/ui/backend/QtWebView.qml'
        // | sha1sum`
        const QString knownHash = QStringLiteral("af3e3f219523c0bba225bf9d3ac2488beb6bad8c");

        QCOMPARE(qmlCacheFileName(path), knownHash + QStringLiteral(".qmlc"));

        // Belt-and-suspenders: the same hash computed in-test via the Qt
        // API the implementation itself uses, to catch a suffix-handling
        // regression (qml/js/mjs) separately from the hash itself.
        const QByteArray selfComputed =
            QCryptographicHash::hash(path.toUtf8(), QCryptographicHash::Sha1).toHex();
        QCOMPARE(QString::fromLatin1(selfComputed), knownHash);
    }
};

QTEST_GUILESS_MAIN(TestQmlCachePurge)
#include "tst_qmlcachepurge.moc"
