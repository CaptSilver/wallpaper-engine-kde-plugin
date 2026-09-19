#pragma once
#include <QList>
#include <QString>
#include <QStringList>

namespace wekde
{

// One source file and the cache entry that was (or should have been)
// deleted for it, so a caller can log "source -> cache file" without
// recomputing the cache name itself.
struct QmlCacheEntry {
    QString sourcePath;
    QString cacheFile;
};

// Outcome of one purge pass. removed is every entry actually deleted;
// failed is every entry that existed but could not be deleted
// (permissions, a concurrent writer, etc) -- also worth surfacing to a
// caller, since it means a stale entry is still sitting there.
struct QmlCachePurgeResult {
    QList<QmlCacheEntry> removed;
    QList<QmlCacheEntry> failed;
};

// Qt's QML disk cache validates a compiled entry by comparing the source
// file's mtime, stored at compile time, against QFileInfo::lastModified()
// read back on the next load. On an ostree host (Bazzite, Kinoite)
// every file under /usr carries mtime 0, and Qt's QDateTime
// wrapper treats mtime 0 as *invalid* rather than the epoch -- so there is
// nothing to compare against, and Qt's verifyHeader() falls back to
// accepting whatever is already cached. An entry can only exist for one of
// these files if it was written while the file briefly had a real
// timestamp (an overlay install, or an install made before an ostree
// rebase); Qt itself refuses to *write* a fresh entry for a source with no
// timestamp (CompilationUnit::saveToDisk bails out), so any entry we find
// for a timestamp-less source is unverifiable by construction. Deleting it
// is safe -- the source just gets recompiled and re-cached, normally, on
// its next load.
//
// sourceDirs are walked recursively for *.qml/*.js/*.mjs files. A file
// whose mtime is valid is left untouched, because Qt already validates
// that one correctly. cacheDir is Qt's qmlcache directory (see
// qmlCacheDir() below).
QmlCachePurgeResult purgeUnverifiableQmlCache(const QStringList& sourceDirs,
                                              const QString&     cacheDir);

// The cache file basename Qt's QML engine would use for sourcePath: sha1
// hex of the path string, plus the suffix Qt derives from it by appending
// "c" and taking QFileInfo::completeSuffix() (qml -> qmlc, js -> jsc,
// mjs -> mjsc). Mirrors qtdeclarative's qv4compileddata.cpp
// localCacheFilePath(); Qt also tries a "<source>c" file sitting right
// next to the source before falling back to this cache-directory name, but
// that sibling can never exist for us -- it would have to live on the same
// read-only /usr the source does.
//
// Exposed as its own function (rather than folded into the purge loop) so
// it can be checked against a hand-computed hash directly, without needing
// a real file on disk at a fixed path.
QString qmlCacheFileName(const QString& sourcePath);

// Qt's QML disk cache directory for this process: $QML_DISK_CACHE_PATH if
// set (Qt itself checks that variable before falling back), otherwise
// <CacheLocation>/qmlcache/.
QString qmlCacheDir();

// This plugin's installed QML package directories -- there can be more
// than one on a multi-prefix system -- found the same way Qt's own import
// resolution would find them.
QStringList pluginQmlPackageDirs();

} // namespace wekde
