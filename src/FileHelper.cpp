#include "FileHelper.hpp"
#include <QFile>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QDateTime>
#include <QMutexLocker>
#include <QThreadPool>

#ifdef WEKDE_HAS_MPV
#    include "backend_mpv/ThumbnailGrabber.hpp"
#endif

namespace wekde
{

namespace
{
// True iff `canon` is the root itself or a descendant of `root`. A bare
// QString::startsWith would also accept a *sibling* whose name shares the
// root's prefix (e.g. ".../wek-evil" startsWith ".../wek") — require either
// an exact match or a child separated by '/'.
static bool isUnderRoot(const QString& canon, const QString& root) {
    return canon == root || canon.startsWith(root + QLatin1Char('/'));
}

// Find the index just past the closing '>' of the first real <head start tag
// that is NOT inside an HTML comment. Returns -1 when there is no usable head.
// Attribute-tolerant (matches `<head lang="en">`), case-insensitive,
// allocation-free, no regex.
static int headInsertPos(const QString& html) {
    int searchFrom = 0;
    while (true) {
        const int lt = html.indexOf(QStringLiteral("<head"), searchFrom, Qt::CaseInsensitive);
        if (lt < 0) return -1;
        // Reject "<header"/"<heading": the char after "<head" must be '>',
        // whitespace, or '/'. (When "<head" is at the very end, treat as '>'.)
        const QChar after = (lt + 5 < html.size()) ? html.at(lt + 5) : QChar(u'>');
        const bool  isHeadTag =
            after == QLatin1Char('>') || after.isSpace() || after == QLatin1Char('/');
        // Reject a match inside a comment: the nearest "<!--" before lt has no
        // "-->" between it and lt.
        const int  cOpen     = html.lastIndexOf(QStringLiteral("<!--"), lt);
        const int  cClose    = (cOpen >= 0) ? html.indexOf(QStringLiteral("-->"), cOpen) : -1;
        const bool inComment = cOpen >= 0 && (cClose < 0 || cClose > lt);
        if (isHeadTag && ! inComment) {
            const int gt = html.indexOf(QLatin1Char('>'), lt);
            if (gt >= 0) return gt + 1; // just past the '>' of <head ...>
        }
        searchFrom = lt + 5;
    }
}
} // namespace

FileHelper::FileHelper(QObject* parent): QObject(parent) {
    // Ensure config directory exists
    QDir dir(wallpaperConfigDir());
    if (! dir.exists()) {
        dir.mkpath(".");
    }
}

FileHelper::~FileHelper() {
    // Block until all background tasks finish so a pool-thread lambda
    // can't touch the QObject (mutex / invokeMethod target) after we go
    // out of scope. This is the dlopen'd plugin .so — a UAF here crashes
    // plasmashell.
    m_pool.waitForDone();
}

QString FileHelper::configDir() const {
    QString xdgConfig = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    return xdgConfig + "/wekde";
}

QString FileHelper::wallpaperConfigDir() const { return configDir() + "/wallpaper"; }

QString FileHelper::wallpaperConfigFile(const QString& id) const {
    return wallpaperConfigDir() + "/" + id + ".json";
}

QByteArray FileHelper::readFile(const QString& path) {
    QFile file(path);
    if (! file.open(QIODevice::ReadOnly)) {
        qWarning() << "FileHelper: Cannot open file:" << path;
        return QByteArray();
    }
    return file.readAll();
}

QString FileHelper::qwebChannelSource() {
    QFile file(":/qtwebchannel/qwebchannel.js");
    if (! file.open(QIODevice::ReadOnly)) {
        qWarning() << "FileHelper: Cannot open bundled qwebchannel.js resource";
        return QString();
    }
    return QString::fromUtf8(file.readAll());
}

QString FileHelper::patchedHtml(const QString& path) {
    QFile file(path);
    if (! file.open(QIODevice::ReadOnly)) {
        qWarning() << "FileHelper: Cannot open HTML file:" << path;
        return QString();
    }

    QString html = QString::fromUtf8(file.readAll());

    // Inject a script that patches History API to suppress SecurityError
    // on file:// URLs.  Must run before any other scripts (e.g. Angular).
    static const QString patch = QStringLiteral(
        "<script>"
        "(function(){"
        // Global error handlers for diagnostics
        "window.addEventListener('error',function(e){"
        "console.warn('[WEK] ERROR:',e.message,'at',e.filename+':'+e.lineno+':'+e.colno);"
        "if(e.error&&e.error.stack)console.warn('[WEK] STACK:',e.error.stack);"
        "});"
        "window.addEventListener('unhandledrejection',function(e){"
        "console.warn('[WEK] REJECTION:',e.reason);"
        "if(e.reason&&e.reason.stack)console.warn('[WEK] STACK:',e.reason.stack);"
        "});"
        // Patch History API to suppress SecurityError on file:// URLs
        "var oR=history.replaceState,oP=history.pushState;"
        "history.replaceState=function(){"
        "try{return oR.apply(this,arguments)}"
        "catch(e){if(e.name!=='SecurityError')throw e}"
        "};"
        "history.pushState=function(){"
        "try{return oP.apply(this,arguments)}"
        "catch(e){if(e.name!=='SecurityError')throw e}"
        "}"
        "})();"
        "</script>");

    // Insert after the real <head ...> tag so the shim runs before any other
    // scripts. Attribute-tolerant + comment-aware (untrusted third-party web
    // wallpapers ship arbitrary HTML).
    int pos = headInsertPos(html);
    if (pos < 0) {
        // No usable <head>. Fall back to after <html ...>, then after the
        // doctype, else prepend — but NEVER before <!DOCTYPE> (quirks mode).
        const int htmlOpen = html.indexOf(QStringLiteral("<html"), 0, Qt::CaseInsensitive);
        const int htmlGt   = htmlOpen >= 0 ? html.indexOf(QLatin1Char('>'), htmlOpen) : -1;
        const int docOpen  = html.indexOf(QStringLiteral("<!doctype"), 0, Qt::CaseInsensitive);
        const int docGt    = docOpen >= 0 ? html.indexOf(QLatin1Char('>'), docOpen) : -1;
        pos                = htmlGt >= 0 ? htmlGt + 1 : (docGt >= 0 ? docGt + 1 : 0);
        qWarning() << "FileHelper::patchedHtml: no clean <head>; inserting shim at offset" << pos
                   << "(after <html>/doctype or prepend)";
    }
    html.insert(pos, patch);

    return html;
}

qint64 FileHelper::getDirSize(const QString& path, int depth) {
    // depth <= 0  => unlimited recursion (historical sentinel; see FileHelper.hpp).
    // depth == N  => count files up to N directory levels below `path`
    //                (depth==1 = top-level files only).
    // One unified QDirIterator walk replaces the former two-branch impl
    // (unlimited-vs-hand-rolled-lambda). QDir::Hidden makes hidden files count
    // consistently (the old unlimited branch counted them via bare QDir::Files).
    QDir root(path);
    if (! root.exists()) return 0;
    const QString base = root.absolutePath();
    const QDir    baseDir(base);

    qint64       total = 0;
    QDirIterator it(base,
                    QDir::Files | QDir::Hidden | QDir::NoDotAndDotDot,
                    depth <= 0   ? QDirIterator::Subdirectories
                    : depth == 1 ? QDirIterator::NoIteratorFlags
                                 : QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        if (depth > 1) {
            // Reject files deeper than `depth` levels. A top-level file's relative
            // path has 0 separators (depth 1); each extra separator is one level.
            const QString rel        = baseDir.relativeFilePath(it.filePath());
            const int     fileLevels = rel.count(QLatin1Char('/')) + 1;
            if (fileLevels > depth) continue;
        }
        total += it.fileInfo().size();
    }
    return total;
}

void FileHelper::requestDirSize(const QString& path, int depth) {
    // Pure walk runs on the pool thread; emit marshals back to the GUI.
    // m_pool is per-instance + waitForDone() in dtor — see ~FileHelper.
    m_pool.start([this, path, depth]() {
        const qint64 bytes = getDirSize(path, depth);
        QMetaObject::invokeMethod(
            this,
            [this, path, bytes]() {
                emit dirSizeReady(path, bytes);
            },
            Qt::QueuedConnection);
    });
}

QVariantMap FileHelper::getFolderList(const QString& path, const QVariantMap& opt) {
    QVariantMap result;

    bool        onlyDir   = opt.value("only_dir", true).toBool();
    QStringList fallbacks = opt.value("fallbacks", QStringList()).toStringList();

    // Find first existing directory
    QString folder = path;
    QDir    dir(folder);

    if (! dir.exists()) {
        for (const QString& fb : fallbacks) {
            QDir fbDir(fb);
            if (fbDir.exists()) {
                folder = fb;
                dir    = fbDir;
                break;
            }
        }
    }

    if (! dir.exists()) {
        return QVariantMap(); // Return null/empty
    }

    result["folder"] = folder;

    QVariantList  items;
    QDir::Filters filters = onlyDir ? QDir::Dirs : (QDir::Dirs | QDir::Files);
    filters |= QDir::NoDotAndDotDot;

    for (const QFileInfo& info : dir.entryInfoList(filters)) {
        QVariantMap item;
        item["name"]  = info.fileName();
        item["mtime"] = static_cast<qint64>(info.lastModified().toSecsSinceEpoch());
        items.append(item);
    }

    result["items"] = items;
    return result;
}

QVariantMap FileHelper::readWallpaperConfig(const QString& id) {
    QString filePath = wallpaperConfigFile(id);
    QFile   file(filePath);

    if (! file.exists()) {
        return QVariantMap();
    }

    if (! file.open(QIODevice::ReadOnly)) {
        qWarning() << "FileHelper: Cannot read config:" << filePath;
        return QVariantMap();
    }

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    if (doc.isNull() || ! doc.isObject()) {
        return QVariantMap();
    }

    return doc.object().toVariantMap();
}

void FileHelper::writeWallpaperConfig(const QString& id, const QVariantMap& changed) {
    // Read existing config
    QVariantMap config = readWallpaperConfig(id);

    // Merge changes
    for (auto it = changed.constBegin(); it != changed.constEnd(); ++it) {
        config[it.key()] = it.value();
    }

    // Write back atomically (write-tmp-then-rename) so a crash or full disk
    // mid-write can never truncate the live config — a truncated file would
    // make readWallpaperConfig silently return an empty map (settings lost).
    QString             filePath = wallpaperConfigFile(id);
    const QJsonDocument doc(QJsonObject::fromVariantMap(config));
    if (! atomicWriteJson(filePath, doc)) {
        qWarning() << "FileHelper: Cannot write config:" << filePath;
    }
}

void FileHelper::resetWallpaperConfig(const QString& id) {
    QString filePath = wallpaperConfigFile(id);
    QFile::remove(filePath);
}

bool FileHelper::clearCacheDir(const QString& path) {
    if (path.isEmpty()) return false;
    // Safety belt: refuse anything outside QStandardPaths::CacheLocation.
    // Strip file:// if present and resolve symlinks to defeat path tricks.
    QString native = path;
    if (native.startsWith("file://")) native = native.mid(7);
    const QString cacheRoot =
        QFileInfo(QStandardPaths::writableLocation(QStandardPaths::CacheLocation))
            .canonicalFilePath();
    if (cacheRoot.isEmpty()) return false;
    // Path may not exist (nothing to clear) — canonicalize what we have:
    // existing → its own canonical path; missing → walk up to the first
    // existing ancestor and confirm it's under cacheRoot, then treat the
    // child as a no-op success.
    QString canon = QFileInfo(native).canonicalFilePath();
    if (canon.isEmpty()) {
        // Path doesn't exist. Confirm the parent (or first existing
        // ancestor) is under cacheRoot — if so, "nothing to clear" is a
        // successful no-op.
        QFileInfo fi(native);
        QDir      parent = fi.dir();
        while (! parent.exists() && parent.cdUp()) { /* walk up */
        }
        const QString parentCanon = QFileInfo(parent.absolutePath()).canonicalFilePath();
        if (parentCanon.isEmpty() || ! isUnderRoot(parentCanon, cacheRoot)) {
            qWarning() << "FileHelper::clearCacheDir refused missing path "
                          "outside cache root:"
                       << path;
            return false;
        }
        return true; // nothing to clear
    }
    if (! isUnderRoot(canon, cacheRoot)) {
        qWarning() << "FileHelper::clearCacheDir refused path outside cache root:" << path;
        return false;
    }
    QDir dir(canon);
    if (! dir.exists()) return true; // nothing to clear
    // Remove the directory contents but keep the directory itself so the
    // caller's binding to it (e.g. plugin_info.cache_path) stays valid.
    const QFileInfoList entries =
        dir.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden);
    for (const QFileInfo& fi : entries) {
        if (fi.isSymLink()) {
            // A symlink to a DIRECTORY whose target escapes the cache is the
            // dangerous case — recursing through it would delete the target's
            // contents — so refuse loudly rather than guess. Internal symlinks and
            // file symlinks are safe to unlink as a link (never followed). Note
            // isDir() follows the link, so it is true for a directory symlink.
            if (fi.isDir()) {
                const QString tgt = fi.canonicalFilePath();
                if (tgt.isEmpty() || ! isUnderRoot(tgt, cacheRoot)) {
                    qWarning() << "FileHelper::clearCacheDir refused escaping directory symlink:"
                               << fi.absoluteFilePath() << "->" << fi.symLinkTarget();
                    return false;
                }
            }
            // Unlink the link only — never follow it. QFile::remove on a symlink
            // unlinks the link, not the target.
            if (! QFile::remove(fi.absoluteFilePath())) {
                qWarning() << "FileHelper::clearCacheDir failed to unlink" << fi.absoluteFilePath();
                return false;
            }
            continue;
        }
        if (fi.isDir()) {
            // Defense in depth: confirm the real dir's canonical target is still
            // under cacheRoot before recursing (a TOCTOU-swapped entry, bind
            // mount, or junction can't escape). Reuses the isUnderRoot belt.
            const QString entryCanon = QFileInfo(fi.absoluteFilePath()).canonicalFilePath();
            if (entryCanon.isEmpty() || ! isUnderRoot(entryCanon, cacheRoot)) {
                qWarning() << "FileHelper::clearCacheDir refused entry outside cache root:"
                           << fi.absoluteFilePath();
                return false;
            }
            QDir sub(fi.absoluteFilePath());
            if (! sub.removeRecursively()) {
                qWarning() << "FileHelper::clearCacheDir failed on" << fi.absoluteFilePath();
                return false;
            }
        } else {
            if (! QFile::remove(fi.absoluteFilePath())) {
                qWarning() << "FileHelper::clearCacheDir failed on" << fi.absoluteFilePath();
                return false;
            }
        }
    }
    return true;
}

QVariantList FileHelper::readActiveBindings(const QString& id) {
    QString filePath = wallpaperConfigDir() + "/" + id + "_bindings.json";
    QFile   file(filePath);

    if (! file.exists() || ! file.open(QIODevice::ReadOnly)) {
        return QVariantList();
    }

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    if (doc.isNull() || ! doc.isArray()) {
        return QVariantList();
    }

    return doc.array().toVariantList();
}

void FileHelper::generateThumbnail(const QString& videoPath, const QString& outPath,
                                   double atSeconds) {
    // Short-circuit if cached thumbnail already exists.
    if (QFileInfo::exists(outPath) && QFileInfo(outPath).size() > 0) {
        QMetaObject::invokeMethod(
            this,
            [this, videoPath, outPath]() {
                emit thumbnailReady(videoPath, outPath, true);
            },
            Qt::QueuedConnection);
        return;
    }
#ifndef WEKDE_HAS_MPV
    // Built without libmpv (e.g. CI without libmpv-devel). Synthesize a
    // failure so callers see thumbnailReady(ok=false) and can fall back.
    Q_UNUSED(atSeconds);
    QMetaObject::invokeMethod(
        this,
        [this, videoPath, outPath]() {
            emit thumbnailReady(videoPath, outPath, false);
        },
        Qt::QueuedConnection);
#else
    {
        QMutexLocker lock(&m_inflightMutex);
        if (m_inflight.contains(videoPath)) return;
        m_inflight.insert(videoPath);
    }
    m_pool.start([this, videoPath, outPath, atSeconds]() {
        // Ensure cache dir exists before libmpv writes the JPEG. If mkpath
        // fails (read-only parent, full disk), log the real cause-and-effect
        // chain so the downstream "screenshot-to-file failed" line isn't
        // mis-blamed on libmpv. Worker continues regardless: if the dir
        // somehow exists by the time the screenshot runs we still want the
        // grab to succeed, and otherwise libmpv's own failure logs (now
        // correctly attributed) tell the rest of the story.
        const QString parentDir = QFileInfo(outPath).absolutePath();
        if (! QDir().mkpath(parentDir)) {
            qWarning() << "FileHelper::generateThumbnail: mkpath failed for" << parentDir
                       << "— libmpv screenshot will likely fail too";
        }
        wekde::ThumbnailGrabber grabber;
        const bool              ok = grabber.grab(videoPath, outPath, atSeconds);
        {
            QMutexLocker lock(&m_inflightMutex);
            m_inflight.remove(videoPath);
        }
        QMetaObject::invokeMethod(
            this,
            [this, videoPath, outPath, ok]() {
                emit thumbnailReady(videoPath, outPath, ok);
            },
            Qt::QueuedConnection);
    });
#endif
}

QVariantList FileHelper::scanVideoFolder(const QString& path) {
    static const QStringList kExtensions = { "mp4", "mkv", "webm", "mov", "avi", "m4v" };
    QVariantList             out;
    QDir                     root(path);
    if (! root.exists()) return out;

    // FollowSymlinks: users commonly curate their Videos folder with symlinks
    // pointing at live-wallpaper .mp4s under the WE workshop tree and at
    // external-storage media; we follow them so those entries actually appear
    // in the tab. Qt's QDirIterator records visited canonical paths internally
    // and terminates on cycles (dir/loop -> dir walks the real contents once).
    QDirIterator it(root.absolutePath(),
                    QDir::Files | QDir::NoDotAndDotDot,
                    QDirIterator::Subdirectories | QDirIterator::FollowSymlinks);
    while (it.hasNext()) {
        const QString   full = it.next();
        const QFileInfo fi(full);
        if (! kExtensions.contains(fi.suffix().toLower())) continue;

        QVariantMap entry;
        entry["path"]  = fi.absoluteFilePath();
        entry["name"]  = fi.fileName();
        entry["mtime"] = fi.lastModified().toSecsSinceEpoch();
        entry["size"]  = fi.size();
        out.append(entry);
    }
    return out;
}

bool FileHelper::atomicWriteJson(const QString& path, const QJsonDocument& doc) {
    const QString tmp = path + ".tmp";
    QFile         f(tmp);
    if (! f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "FileHelper::atomicWriteJson: cannot open tmp for write:" << tmp;
        return false;
    }
    const QByteArray bytes = doc.toJson(QJsonDocument::Indented);
    if (f.write(bytes) != bytes.size()) {
        qWarning() << "FileHelper::atomicWriteJson: short write to" << tmp;
        f.close();
        QFile::remove(tmp);
        return false;
    }
    if (! f.flush()) {
        qWarning() << "FileHelper::atomicWriteJson: flush failed on" << tmp;
        f.close();
        QFile::remove(tmp);
        return false;
    }
    f.close();
    // QFile::rename will not overwrite on POSIX; remove target first.
    if (QFile::exists(path)) QFile::remove(path);
    if (! QFile::rename(tmp, path)) {
        qWarning() << "FileHelper::atomicWriteJson: rename failed" << tmp << "->" << path;
        QFile::remove(tmp);
        return false;
    }
    return true;
}

} // namespace wekde
