#include "FileHelper.hpp"
#include "CachePaths.hpp"
#include <QFile>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QDateTime>
#include <QMutexLocker>
#include <QThreadPool>
#include <QHash>
#include <QVariant>
#include <algorithm>
#include <functional>
#include <optional>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <unistd.h>

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

// Same containment rule minus the exact-match arm. Every destructive cache
// entry point uses this one: the guard root is the whole user cache
// directory, so accepting an exact match would let a stray cache_path of
// "~/.cache" wipe every other application's cache too.
static bool isStrictlyUnderRoot(const QString& canon, const QString& root) {
    return ! root.isEmpty() && canon.startsWith(root + QLatin1Char('/'));
}

// True iff `canon` is under any root in `roots`. Empty canon never matches
// (defeats the "non-existent path canonicalises to empty string and would
// match the empty root if one ever slipped in" footgun).
static bool isUnderAnyRoot(const QString& canon, const QSet<QString>& roots) {
    if (canon.isEmpty()) return false;
    for (const QString& root : roots) {
        if (isUnderRoot(canon, root)) return true;
    }
    return false;
}

// Sidecar path for a thumbnail JPEG: strip a trailing `.jpg` (case-insensitive)
// and substitute `.meta`. If `thumbPath` doesn't end in `.jpg` we append `.meta`
// — the orphan-GC keeps backwards-safe behaviour either way (entries without a
// matching sidecar are kept).
static QString sidecarFor(const QString& thumbPath) {
    if (thumbPath.endsWith(QStringLiteral(".jpg"), Qt::CaseInsensitive))
        return thumbPath.left(thumbPath.size() - 4) + QStringLiteral(".meta");
    return thumbPath + QStringLiteral(".meta");
}

// Write the sidecar JSON describing the source `videoPath` next to `outPath`.
// Best-effort — failure is logged and otherwise ignored (the thumbnail itself
// is still useful; the sidecar only anchors the orphan-GC).
static void writeSidecar(const QString& outPath, const QString& videoPath) {
    const QString sidecarPath = sidecarFor(outPath);
    QFile         f(sidecarPath);
    if (! f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "FileHelper::writeSidecar: cannot open" << sidecarPath;
        return;
    }
    QJsonObject obj;
    obj["src"] = videoPath;
    const QJsonDocument doc(obj);
    f.write(doc.toJson(QJsonDocument::Compact));
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

// Read a file the plugin was handed by a wallpaper, refusing anything that is
// not a regular file and stopping at kMaxReadSize. `who` names the caller in
// the warnings; nullopt means "refused", and the caller decides what an empty
// result looks like on its own signature.
//
// The type check has to come BEFORE the open: open(2) on a fifo parks until a
// writer arrives, which freezes whichever thread called in — the GUI thread
// for readFile, or a pool thread that ~FileHelper joins with no timeout for
// requestReadFile. It is also the only thing standing between a symlink to
// /dev/zero and an unbounded read, because st_size is 0 for character
// devices, fifos and procfs entries, so the size cap below cannot see them.
std::optional<QByteArray> readRegularFileCapped(const QString& native, const char* who) {
    const QFileInfo info(native);
    if (! info.exists()) {
        qWarning() << who << "no such file:" << native;
        return std::nullopt;
    }
    if (! info.isFile()) {
        qWarning() << who << "refused non-regular file:" << native;
        return std::nullopt;
    }

    QFile file(native);
    if (! file.open(QIODevice::ReadOnly)) {
        qWarning() << who << "cannot open file:" << native;
        return std::nullopt;
    }

    const qint64 declared = file.size();
    if (declared > FileHelper::kMaxReadSize) {
        qWarning() << who << "refused over-size file:" << native << "(" << declared << "bytes >"
                   << FileHelper::kMaxReadSize << ")";
        return std::nullopt;
    }

    // Chunked instead of readAll(): st_size is a hint, not a promise. A
    // regular file can grow between the stat and the read, so the cap is
    // enforced against the bytes that actually arrive.
    constexpr qint64 kChunk = 64 * 1024;
    QByteArray       out;
    if (declared > 0) out.reserve(declared);
    QByteArray buf(kChunk, Qt::Uninitialized);
    for (;;) {
        const qint64 n = file.read(buf.data(), kChunk);
        if (n < 0) {
            qWarning() << who << "read failed on" << native << ":" << file.errorString();
            return std::nullopt;
        }
        if (n == 0) break;
        if (out.size() + n > FileHelper::kMaxReadSize) {
            qWarning() << who << "refused file that grew past" << FileHelper::kMaxReadSize
                       << "bytes mid-read:" << native;
            return std::nullopt;
        }
        out.append(buf.constData(), n);
    }
    return out;
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
    // Strip file:// once, up front, and open the stripped form — requestReadFile
    // does the same, and QML callers pass both shapes.
    QString native = path;
    if (native.startsWith("file://")) native = native.mid(7);

    // Allowlist check (fail-closed when seeded, permissive when empty for
    // first-run back-compat). Canonicalisation resolves symlinks + ".." +
    // CWD-relative — the canonical form is what we compare to the seeded
    // roots, so a symlink INSIDE an allowed root pointing OUTSIDE it is
    // refused.
    if (! m_readRoots.isEmpty()) {
        const QString canon = QFileInfo(native).canonicalFilePath();
        if (! isUnderAnyRoot(canon, m_readRoots)) {
            qWarning() << "FileHelper::readFile refused path outside allowed roots:" << path
                       << "(canon:" << canon << ")";
            return QByteArray();
        }
    }

    // Type check + size cap apply in BOTH allowlist modes.
    return readRegularFileCapped(native, "FileHelper::readFile").value_or(QByteArray());
}

void FileHelper::addReadRoot(const QString& path) {
    // Strip file:// so QML callers passing Common.urlNative()-style URLs
    // OR raw QUrls both work — mirrors clearCacheDir's pre-canon strip.
    QString native = path;
    if (native.startsWith("file://")) native = native.mid(7);
    const QString canon = QFileInfo(native).canonicalFilePath();
    if (canon.isEmpty()) {
        // Non-existent path: refuse loudly. Inserting an empty string here
        // would silently poison the set (canon.startsWith("") is true for
        // every string), turning the gate back into permissive mode.
        qWarning() << "FileHelper::addReadRoot refused non-existent path:" << path;
        return;
    }
    m_readRoots.insert(canon);
}

void FileHelper::clearReadRoots() { m_readRoots.clear(); }

QString FileHelper::qwebChannelSource() {
    QFile file(":/qtwebchannel/qwebchannel.js");
    if (! file.open(QIODevice::ReadOnly)) {
        qWarning() << "FileHelper: Cannot open bundled qwebchannel.js resource";
        return QString();
    }
    return QString::fromUtf8(file.readAll());
}

QString FileHelper::patchedHtml(const QString& path) {
    // Same gate as readFile: the path comes from a wallpaper directory, and a
    // fifo here would park the GUI thread inside open(2) forever.
    const auto bytes = readRegularFileCapped(path, "FileHelper::patchedHtml");
    if (! bytes) return QString();

    QString html = QString::fromUtf8(*bytes);

    // Inject a script that patches History API to suppress SecurityError
    // on file:// URLs.  Must run before any other scripts (e.g. Angular).
    static const QString patch =
        QStringLiteral("<script>"
                       "(function(){"
                       // Page-side error handlers — routed through console.error so the
                       // QML onJavaScriptConsoleMessage handler picks them up at level 2,
                       // and prefixed [WEK-page UNCAUGHT/UNHANDLED-PROMISE/STACK] so the
                       // `journalctl /usr/bin/plasmashell -f | grep WEK-page` workflow
                       // catches them in one filter.
                       "window.addEventListener('error',function(e){"
                       "var src=(e.filename||'<inline>')+':'+(e.lineno||0)+':'+(e.colno||0);"
                       "console.error('[WEK-page UNCAUGHT] '+src+' '+(e.message||e.error));"
                       "if(e.error&&e.error.stack)console.error('[WEK-page STACK] '+e.error.stack);"
                       "});"
                       "window.addEventListener('unhandledrejection',function(e){"
                       "var r=e.reason&&(e.reason.stack||e.reason.message||e.reason);"
                       "console.error('[WEK-page UNHANDLED-PROMISE] '+r);"
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

void FileHelper::requestReadFile(const QString& path) {
    // Pool-thread lambda performs canonicalise + allowlist + size-cap + read,
    // then marshals fileReadReady back to the GUI thread. Cold-cache scans of
    // ~1000 workshop project.json files used to block the GUI for tens of
    // seconds via Pyext.qml's sham _makePromise wrapper over the synchronous
    // readFile; this gets the work off the GUI thread without bypassing any of
    // the gates the sync readFile enforces. m_pool waitForDone() in the dtor
    // keeps `this` alive until in-flight lambdas finish.
    //
    // The allowlist is snapshotted here, on the calling thread — the worker must
    // never touch m_readRoots. QML rewrites that set on every settings change
    // (clearReadRoots() then one addReadRoot() per entry) while a library scan's
    // worth of jobs is still queued, so a worker reading the member would iterate
    // a QSet the GUI thread is rehashing or has already freed. The copy is a
    // refcount bump, not a deep copy — QSet is implicitly shared. It also fixes
    // the semantics: a job is judged by the allowlist in force when it was
    // queued, so changing the Steam library mid-scan no longer retroactively
    // refuses reads already in flight.
    m_pool.start([this, path, roots = m_readRoots]() {
        QByteArray contents;
        bool       ok = false;

        // Strip file:// to match readFile() / addReadRoot() — QML callers
        // sometimes pass through Common.urlNative, sometimes not.
        QString native = path;
        if (native.startsWith("file://")) native = native.mid(7);

        // Canonicalise; non-existent paths canonicalise to empty string.
        const QString canon = QFileInfo(native).canonicalFilePath();

        const bool allowlistOk = roots.isEmpty() ? true : isUnderAnyRoot(canon, roots);
        if (! allowlistOk) {
            qWarning() << "FileHelper::requestReadFile refused path outside allowed roots:" << path
                       << "(canon:" << canon << ")";
        } else if (auto bytes = readRegularFileCapped(native, "FileHelper::requestReadFile")) {
            contents = std::move(*bytes);
            ok       = true;
        }

        // Deliver on the GUI thread. Capture by value — `this` is kept alive
        // by m_pool.waitForDone() in the dtor.
        QMetaObject::invokeMethod(
            this,
            [this, path, contents, ok]() {
                emit fileReadReady(path, contents, ok);
            },
            Qt::QueuedConnection);
    });
}

void FileHelper::watchWallpaperDir(const QString& path) {
    if (path.isEmpty()) return;
    // Strip file:// to match the other path-taking entry points (addReadRoot,
    // clearCacheDir). QML callers often pass through Common.urlNative which
    // already strips it, but not always.
    QString native = path;
    if (native.startsWith("file://")) native = native.mid(7);

    // QFileSystemWatcher::addPath silently logs a warning + returns false on
    // non-existent paths; do the existence check up-front so the warning is
    // actionable. A missing path is normal during Steam library uninstall.
    QFileInfo info(native);
    if (! info.isDir()) {
        qWarning() << "FileHelper::watchWallpaperDir: path is not a directory:" << path;
        return;
    }
    if (! m_wallpaperDirWatcher) {
        m_wallpaperDirWatcher = new QFileSystemWatcher(this);
        connect(m_wallpaperDirWatcher,
                &QFileSystemWatcher::directoryChanged,
                this,
                [this](const QString& p) {
                    emit wallpaperDirChanged(p);
                });
    }
    // Qt's addPath silently dedups against currently-watched paths and
    // returns false if the watcher is full or the path is unreadable —
    // both safe to ignore.
    m_wallpaperDirWatcher->addPath(native);
}

void FileHelper::unwatchAllWallpaperDirs() {
    if (! m_wallpaperDirWatcher) return;
    const auto dirs = m_wallpaperDirWatcher->directories();
    if (! dirs.isEmpty()) m_wallpaperDirWatcher->removePaths(dirs);
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

namespace
{
// Deepest directory nesting clearCacheDir will descend. The renderer cache is
// two or three levels (<cache>/<sceneId>/spvsNN); anything approaching this is
// a mistake or an attempt to blow the stack of a .so living inside
// plasmashell, so stop and say so rather than recursing into it.
constexpr int kMaxCacheDepth = 32;

// Remove the contents of `dirPath`, recursively, keeping anything
// isPreservedCacheFile() flags as user state plus any directory that still
// holds one. `cacheRoot` anchors the symlink-escape and TOCTOU re-checks at
// every level, not just the top. Sets `keptSomething` when a preserved file
// survived below `dirPath`. Returns false on the first hard failure.
bool clearCacheContents(const QString& dirPath, const QString& cacheRoot, bool& keptSomething,
                        int depth = 0) {
    if (depth > kMaxCacheDepth) {
        qWarning() << "FileHelper::clearCacheDir refused to descend past" << kMaxCacheDepth
                   << "levels at" << dirPath;
        return false;
    }
    QDir dir(dirPath);
    if (! dir.exists()) return true;
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
            bool keptInside = false;
            if (! clearCacheContents(entryCanon, cacheRoot, keptInside, depth + 1)) return false;
            if (keptInside) {
                keptSomething = true;
                continue; // the directory still holds user state
            }
            if (! dir.rmdir(fi.fileName())) {
                qWarning() << "FileHelper::clearCacheDir failed on" << fi.absoluteFilePath();
                return false;
            }
        } else {
            if (cache_paths::isPreservedCacheFile(fi.fileName())) {
                keptSomething = true;
                continue;
            }
            if (! QFile::remove(fi.absoluteFilePath())) {
                qWarning() << "FileHelper::clearCacheDir failed on" << fi.absoluteFilePath();
                return false;
            }
        }
    }
    return true;
}
} // namespace

bool FileHelper::clearCacheDir(const QString& path) {
    if (path.isEmpty()) return false;
    // Safety belt: refuse anything that is not a strict descendant of the
    // user cache root. Strip file:// if present and resolve symlinks to
    // defeat path tricks.
    QString native = path;
    if (native.startsWith("file://")) native = native.mid(7);
    const QString cacheRoot = cache_paths::userCacheRoot();
    if (cacheRoot.isEmpty()) return false;
    // Path may not exist (nothing to clear) — canonicalize what we have:
    // existing → its own canonical path; missing → walk up to the first
    // existing ancestor and confirm it's under cacheRoot, then treat the
    // child as a no-op success.
    QString canon = QFileInfo(native).canonicalFilePath();
    if (canon.isEmpty()) {
        // Path doesn't exist. Confirm the parent (or first existing
        // ancestor) is under cacheRoot — if so, "nothing to clear" is a
        // successful no-op. The ancestor may BE the root: the missing child
        // is then still a strict descendant, and this branch deletes nothing
        // either way.
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
    if (! isStrictlyUnderRoot(canon, cacheRoot)) {
        qWarning() << "FileHelper::clearCacheDir refused path outside cache root:" << path;
        return false;
    }
    QDir dir(canon);
    if (! dir.exists()) return true; // nothing to clear
    // Remove the directory contents but keep the directory itself so the
    // caller's binding to it (e.g. plugin_info.cache_path) stays valid.
    bool kept = false;
    return clearCacheContents(canon, cacheRoot, kept);
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
        // Refresh the sidecar if it's missing — users with pre-feature
        // thumbnails get one written on first re-touch so the orphan-GC
        // becomes effective without requiring a manual cache wipe.
        if (! QFileInfo::exists(sidecarFor(outPath))) writeSidecar(outPath, videoPath);
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
        if (ok) {
            // Anchor this entry to its source so the orphan-GC can later
            // map outPath -> videoPath. Best-effort; thumbnail still valid
            // even if the sidecar write fails.
            writeSidecar(outPath, videoPath);
        }
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

// ── Orphan-GC + quota helpers ─────────────────────────────────────────────────

namespace
{
// True iff a thumbnail's source is still worth keeping a thumbnail for. Used
// by pruneOrphanThumbnails.
//
// `roots` are CLEANED, not canonicalised — canonicalising drops the roots
// that matter most here, because a root on an unplugged drive canonicalises
// to an empty string and vanishes from the set. Which is why this comparison
// is textual.
bool sourceStillLive(const QString& src, const QSet<QString>& roots) {
    if (src.isEmpty()) return false;
    // The cheap test first — also covers Videos-tab sources that are absolute
    // symlinks outside any seeded root.
    if (QFileInfo::exists(src)) return true;
    const QString clean = QDir::cleanPath(src);
    for (const QString& root : roots) {
        if (! isUnderRoot(clean, root)) continue;
        // The source is gone but its root is recorded. Keep the thumbnail iff
        // that root is not currently visible (drive unplugged, Steam library
        // unmounted) — the source may well come back. Root present and file
        // gone means the user deleted the wallpaper: orphan.
        return ! QFileInfo::exists(root);
    }
    return false;
}
} // namespace

QString FileHelper::videoThumbDir(const QString& cacheRoot) {
    if (cacheRoot.isEmpty()) return {};
    QString native = cacheRoot;
    if (native.startsWith("file://")) native = native.mid(7);
    while (native.size() > 1 && native.endsWith(QLatin1Char('/'))) native.chop(1);
    return native + QStringLiteral("/video-thumbs");
}

qint64 FileHelper::pruneOrphanThumbnails(const QString&     cacheRoot,
                                         const QStringList& installedWallpaperDirs,
                                         const QStringList& videoFolderPaths) {
    if (cacheRoot.isEmpty()) return 0;
    // Safety belt: refuse anything that is not a strict descendant of the
    // user cache root. Mirrors clearCacheDir.
    QString native = cacheRoot;
    if (native.startsWith("file://")) native = native.mid(7);
    const QString cacheRootCanon = cache_paths::userCacheRoot();
    if (cacheRootCanon.isEmpty()) return 0;
    const QString canon = QFileInfo(native).canonicalFilePath();
    if (canon.isEmpty()) return 0; // dir doesn't exist => nothing to do
    if (! isStrictlyUnderRoot(canon, cacheRootCanon)) {
        qWarning() << "FileHelper::pruneOrphanThumbnails refused path outside cache root:"
                   << cacheRoot;
        return 0;
    }

    // Root set from installedWallpaperDirs + videoFolderPaths. Cleaned, NOT
    // canonicalised: a root on an unplugged drive canonicalises to an empty
    // string, and dropping it here is what made the unmounted-library case
    // reap thumbnails it should have kept.
    QSet<QString> roots;
    auto          addRoot = [&](const QString& p) {
        if (p.isEmpty()) return;
        QString s = p;
        if (s.startsWith("file://")) s = s.mid(7);
        roots.insert(QDir::cleanPath(s));
    };
    for (const QString& p : installedWallpaperDirs) addRoot(p);
    for (const QString& p : videoFolderPaths) addRoot(p);

    qint64 freed = 0;
    // Callers hand over the cache ROOT; the thumbnails are one level down.
    QDir dir(videoThumbDir(canon));
    if (! dir.exists()) return 0;
    // Walk top-level files only — video-thumbs is a flat dir of <hash>.jpg.
    const QFileInfoList entries =
        dir.entryInfoList(QStringList { QStringLiteral("*.meta") }, QDir::Files);
    for (const QFileInfo& fi : entries) {
        const QString metaPath = fi.absoluteFilePath();
        // Verify the sidecar canonically lies under cacheRootCanon. Defense
        // in depth against a TOCTOU swap or escaping symlink.
        const QString metaCanon = QFileInfo(metaPath).canonicalFilePath();
        if (metaCanon.isEmpty() || ! isUnderRoot(metaCanon, cacheRootCanon)) {
            qWarning() << "FileHelper::pruneOrphanThumbnails refused entry outside cache root:"
                       << metaPath;
            continue;
        }
        QFile mf(metaPath);
        if (! mf.open(QIODevice::ReadOnly)) continue;
        const QJsonDocument doc = QJsonDocument::fromJson(mf.readAll());
        mf.close();
        if (doc.isNull() || ! doc.isObject()) continue;
        const QString src = doc.object().value("src").toString();
        if (sourceStillLive(src, roots)) continue;

        // Orphan — drop the .meta and its companion .jpg (if any).
        const QString jpgPath  = metaPath.left(metaPath.size() - 5) + QStringLiteral(".jpg");
        const qint64  jpgBytes = QFile::exists(jpgPath) ? QFileInfo(jpgPath).size() : 0;
        const qint64  meBytes  = fi.size();
        QFile::remove(metaPath);
        if (QFile::exists(jpgPath)) QFile::remove(jpgPath);
        freed += jpgBytes + meBytes;
    }
    return freed;
}

qint64 FileHelper::sweepCacheQuota(const QStringList& roots, qint64 quotaBytes) {
    if (quotaBytes <= 0) return 0; // 0 = unlimited
    const QString cacheRootCanon = cache_paths::userCacheRoot();
    if (cacheRootCanon.isEmpty()) return 0;

    // Collect every regular file under each root, with its atime + size.
    struct Entry {
        QString path;
        qint64  atime { 0 };
        qint64  size { 0 };
    };
    QList<Entry> all;
    qint64       total = 0;
    for (const QString& root : roots) {
        if (root.isEmpty()) continue;
        QString native = root;
        if (native.startsWith("file://")) native = native.mid(7);
        const QString canon = QFileInfo(native).canonicalFilePath();
        if (canon.isEmpty()) continue;
        if (! isStrictlyUnderRoot(canon, cacheRootCanon)) {
            qWarning() << "FileHelper::enforceCacheQuota refused root outside cache:" << root;
            continue;
        }
        QDirIterator it(canon, QDir::Files | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString   fp = it.next();
            const QFileInfo fi(fp);
            // Per-entry containment re-check, matching clearCacheDir and
            // pruneOrphanThumbnails. An entry whose real target sits outside
            // the cache — a symlink, a bind mount — is not our storage: don't
            // count its bytes and don't delete it.
            const QString entryCanon = fi.canonicalFilePath();
            if (entryCanon.isEmpty() || ! isUnderRoot(entryCanon, cacheRootCanon)) {
                qWarning() << "FileHelper::enforceCacheQuota refused entry outside cache root:"
                           << fi.absoluteFilePath();
                continue;
            }
            Entry e;
            e.path = fi.absoluteFilePath();
            // Prefer atime (recent reads bump it on relatime mounts); fall
            // back to mtime when atime <= mtime (a heuristic for noatime
            // mounts where atime is frozen at create-time).
            const qint64 atime = fi.lastRead().toMSecsSinceEpoch();
            const qint64 mtime = fi.lastModified().toMSecsSinceEpoch();
            e.atime            = (atime > mtime) ? atime : mtime;
            e.size             = fi.size();
            total += e.size;
            // Persistent state counts toward the footprint the user asked us
            // to cap, but it is never a candidate: SceneScript localStorage is
            // the wallpaper's save data and nothing regenerates it.
            if (cache_paths::isPreservedCacheFile(e.path)) continue;
            all.append(e);
        }
    }
    if (total <= quotaBytes) return 0; // under quota — no eviction needed

    // Sort oldest-first by atime; delete until under cap.
    std::sort(all.begin(), all.end(), [](const Entry& a, const Entry& b) {
        return a.atime < b.atime;
    });
    qint64 freed = 0;
    for (const Entry& e : all) {
        if (total <= quotaBytes) break;
        if (! QFile::remove(e.path)) {
            qWarning() << "FileHelper::enforceCacheQuota: cannot delete" << e.path;
            continue;
        }
        freed += e.size;
        total -= e.size;
        // Drop matching sidecar (or vice-versa: if we deleted a .meta, drop
        // its .jpg). The pairing keeps the orphan-GC tally consistent.
        if (e.path.endsWith(QStringLiteral(".jpg"), Qt::CaseInsensitive)) {
            const QString sc = sidecarFor(e.path);
            if (QFile::exists(sc)) {
                const qint64 sz = QFileInfo(sc).size();
                if (QFile::remove(sc)) {
                    freed += sz;
                    total -= sz;
                }
            }
        } else if (e.path.endsWith(QStringLiteral(".meta"), Qt::CaseInsensitive)) {
            const QString jp = e.path.left(e.path.size() - 5) + QStringLiteral(".jpg");
            if (QFile::exists(jp)) {
                const qint64 sz = QFileInfo(jp).size();
                if (QFile::remove(jp)) {
                    freed += sz;
                    total -= sz;
                }
            }
        }
    }
    return freed;
}

qint64 FileHelper::enforceCacheQuotaForce(const QStringList& roots, qint64 quotaBytes) {
    const qint64 freed = sweepCacheQuota(roots, quotaBytes);
    // Arm the throttle on every completed walk, not just the ones that
    // evicted: "one run per minute" is about the cost of the walk, and the
    // under-quota case is the common one.
    m_lastEnforceMs = QDateTime::currentMSecsSinceEpoch();
    // Leave m_lastGcBytesFreed alone on a no-op run so the UI keeps showing
    // the most recent real activity instead of flickering back to 0.
    if (freed > 0 && freed != m_lastGcBytesFreed) {
        m_lastGcBytesFreed = freed;
        emit lastGcBytesFreedChanged();
    }
    return freed;
}

void FileHelper::requestCacheGc(const QString& cacheRoot, const QStringList& installedWallpaperDirs,
                                const QStringList& videoFolderPaths, qint64 quotaBytes) {
    if (cacheRoot.isEmpty()) return;
    // Throttle here, on the calling (GUI) thread, so a burst of wallpaper
    // switches can't queue one full tree walk per switch.
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_lastEnforceMs != 0 && (now - m_lastEnforceMs) < kGcCooldownMs) return;
    // Both halves are pure walks over the filesystem — no instance state —
    // so they are safe on a pool thread. The bookkeeping and the signal
    // marshal back to the GUI thread. m_pool is per-instance and the dtor
    // waitForDone()s it, so `this` outlives the job.
    m_pool.start([this, cacheRoot, installedWallpaperDirs, videoFolderPaths, quotaBytes]() {
        const qint64 pruned =
            pruneOrphanThumbnails(cacheRoot, installedWallpaperDirs, videoFolderPaths);
        const qint64 evicted = sweepCacheQuota({ cacheRoot }, quotaBytes);
        QMetaObject::invokeMethod(
            this,
            [this, pruned, evicted]() {
                m_lastEnforceMs = QDateTime::currentMSecsSinceEpoch();
                if (evicted > 0 && evicted != m_lastGcBytesFreed) {
                    m_lastGcBytesFreed = evicted;
                    emit lastGcBytesFreedChanged();
                }
                emit cacheGcFinished(pruned, evicted);
            },
            Qt::QueuedConnection);
    });
}

qint64 FileHelper::enforceCacheQuota(const QStringList& roots, qint64 quotaBytes) {
    // Throttle: skip if a run completed within the last minute. The "Run
    // cache GC now" button calls enforceCacheQuotaForce to bypass.
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_lastEnforceMs != 0 && (now - m_lastEnforceMs) < kGcCooldownMs) {
        return m_lastGcBytesFreed; // Report previous, no work this call.
    }
    return enforceCacheQuotaForce(roots, quotaBytes);
}

// ── Steam Workshop manifest (Valve KVFormat) ──────────────────────────────────

namespace
{
// Tiny Valve-KV lexer. The grammar we accept is a strict subset that covers
// every appworkshop_<appid>.acf Steam emits:
//
//   file   := pair*
//   pair   := STRING (STRING | object)
//   object := '{' pair* '}'
//
// STRING is a `"…"` quoted token (no escapes in practice in Steam's writer;
// we tolerate `\"`, `\\`, `\n`, `\t`). Whitespace is any ASCII <= 0x20.
//
// Returns a QVariantMap mirroring the tree (string => QString or nested
// QVariantMap); std::nullopt on syntax error. Fail-soft: callers treat any
// parse failure as "no manifest" and badge nothing.
std::optional<QVariantMap> parseValveKV(const QString& text) {
    int       pos = 0;
    const int n   = text.size();

    auto skipWs = [&]() {
        while (pos < n) {
            const QChar c = text.at(pos);
            // Treat ASCII <= 0x20 as whitespace AND skip C-style // comments
            // (Steam doesn't emit them, but some hand-edited acfs have them).
            if (c.unicode() <= 0x20) {
                ++pos;
            } else if (c == QLatin1Char('/') && pos + 1 < n &&
                       text.at(pos + 1) == QLatin1Char('/')) {
                while (pos < n && text.at(pos) != QLatin1Char('\n')) ++pos;
            } else {
                break;
            }
        }
    };

    auto parseString = [&](QString& out) -> bool {
        skipWs();
        if (pos >= n || text.at(pos) != QLatin1Char('"')) return false;
        ++pos; // consume opening "
        out.clear();
        while (pos < n) {
            const QChar c = text.at(pos++);
            if (c == QLatin1Char('"')) return true;
            if (c == QLatin1Char('\\') && pos < n) {
                const QChar esc = text.at(pos++);
                if (esc == QLatin1Char('n'))
                    out.append(QLatin1Char('\n'));
                else if (esc == QLatin1Char('t'))
                    out.append(QLatin1Char('\t'));
                else if (esc == QLatin1Char('r'))
                    out.append(QLatin1Char('\r'));
                else
                    out.append(esc); // \\ \" and anything else literal
            } else {
                out.append(c);
            }
        }
        return false; // unterminated string
    };

    // Forward declare so parsePairs can recurse into nested objects via
    // std::function (lambda capture limits prevent direct recursion).
    std::function<bool(QVariantMap&)> parsePairs;

    parsePairs = [&](QVariantMap& out) -> bool {
        while (true) {
            skipWs();
            if (pos >= n) return true;
            if (text.at(pos) == QLatin1Char('}')) return true; // caller consumes
            QString key;
            if (! parseString(key)) return false;
            skipWs();
            if (pos >= n) return false;
            const QChar nxt = text.at(pos);
            if (nxt == QLatin1Char('"')) {
                QString val;
                if (! parseString(val)) return false;
                out.insert(key, val);
            } else if (nxt == QLatin1Char('{')) {
                ++pos;
                QVariantMap nested;
                if (! parsePairs(nested)) return false;
                skipWs();
                if (pos >= n || text.at(pos) != QLatin1Char('}')) return false;
                ++pos; // consume }
                out.insert(key, nested);
            } else {
                return false;
            }
        }
    };

    QVariantMap root;
    if (! parsePairs(root)) return std::nullopt;
    skipWs();
    if (pos != n) return std::nullopt; // trailing garbage
    return root;
}
} // namespace

QVariantMap FileHelper::readWorkshopManifest(const QString& steamLibraryPath) {
    QVariantMap empty;
    if (steamLibraryPath.isEmpty()) return empty;
    QString lib = steamLibraryPath;
    if (lib.startsWith("file://")) lib = lib.mid(7);
    const QString acfPath = lib + "/steamapps/workshop/appworkshop_431960.acf";
    QFile         f(acfPath);
    if (! f.exists() || ! f.open(QIODevice::ReadOnly | QIODevice::Text)) return empty;
    const QString text = QString::fromUtf8(f.readAll());
    f.close();
    const auto parsed = parseValveKV(text);
    if (! parsed.has_value()) return empty;
    // Walk AppWorkshop -> WorkshopItemsInstalled -> <id> -> timeupdated.
    const QVariantMap appWorkshop = parsed->value(QStringLiteral("AppWorkshop")).toMap();
    const QVariantMap installed =
        appWorkshop.value(QStringLiteral("WorkshopItemsInstalled")).toMap();
    QVariantMap out;
    for (auto it = installed.constBegin(); it != installed.constEnd(); ++it) {
        const QVariantMap entry = it.value().toMap();
        const QString     ts    = entry.value(QStringLiteral("timeupdated")).toString();
        // Missing or unparseable timeupdated => 0. qint64 keeps full Steam
        // timestamps (32-bit unix epoch fits trivially, leave room for
        // Y2038 + Steam-future).
        bool         ok    = false;
        const qint64 value = ts.toLongLong(&ok);
        out.insert(it.key(), ok ? value : qint64 { 0 });
    }
    return out;
}

qint64 FileHelper::seenVersion(const QString& id) const {
    const QString filePath = wallpaperConfigFile(id);
    QFile         f(filePath);
    if (! f.exists() || ! f.open(QIODevice::ReadOnly)) return 0;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (doc.isNull() || ! doc.isObject()) return 0;
    const QJsonValue v = doc.object().value(QStringLiteral("last_seen_version"));
    if (! v.isDouble()) return 0;
    // toVariant().toLongLong handles the JSON-double-fits-int53 edge cleanly.
    return v.toVariant().toLongLong();
}

void FileHelper::recordSeenVersion(const QString& id, qint64 timeUpdated) {
    if (id.isEmpty()) return;
    // Read existing config, merge in last_seen_version, write atomically.
    // Mirrors writeWallpaperConfig's read-merge-write pattern but exposes
    // a single-key fast path so callers don't need to round-trip a full
    // QVariantMap.
    const QString filePath = wallpaperConfigFile(id);
    QJsonObject   obj;
    QFile         in(filePath);
    if (in.exists() && in.open(QIODevice::ReadOnly)) {
        const QJsonDocument d = QJsonDocument::fromJson(in.readAll());
        if (! d.isNull() && d.isObject()) obj = d.object();
        in.close();
    }
    obj["last_seen_version"] = static_cast<double>(timeUpdated);
    if (! atomicWriteJson(filePath, QJsonDocument(obj))) {
        qWarning() << "FileHelper::recordSeenVersion: write failed for" << filePath;
    }
}

QVariantMap FileHelper::allSeenVersions() const {
    QVariantMap out;
    QDir        dir(wallpaperConfigDir());
    if (! dir.exists()) return out;
    const QFileInfoList entries =
        dir.entryInfoList(QStringList { QStringLiteral("*.json") }, QDir::Files);
    for (const QFileInfo& fi : entries) {
        // Skip bindings files (id_bindings.json); only per-wallpaper config
        // files carry last_seen_version.
        if (fi.completeBaseName().endsWith("_bindings")) continue;
        const QString id = fi.completeBaseName();
        const qint64  v  = seenVersion(id);
        if (v != 0) out.insert(id, v);
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
    // flush() only empties Qt's userspace buffer. Get the bytes onto the disk
    // before the rename, or a crash straight after it leaves `path` naming a
    // zero-length file — the exact outcome the temp-file dance exists to avoid.
    // EINVAL means the filesystem has no sync to perform (some FUSE mounts) —
    // nothing was lost, so it is not a write failure.
    if (::fsync(f.handle()) != 0 && errno != EINVAL) {
        qWarning() << "FileHelper::atomicWriteJson: fsync failed on" << tmp << ":"
                   << std::strerror(errno);
        f.close();
        QFile::remove(tmp);
        return false;
    }
    f.close();
    // rename(2) replaces the directory entry in one step, so a concurrent
    // reader sees either the old file or the new one and never a gap. Qt's
    // QFile::rename refuses to overwrite and unlinking the target first would
    // hand back exactly the gap this is here to prevent.
    if (std::rename(QFile::encodeName(tmp).constData(), QFile::encodeName(path).constData()) != 0) {
        qWarning() << "FileHelper::atomicWriteJson: rename failed" << tmp << "->" << path << ":"
                   << std::strerror(errno);
        QFile::remove(tmp);
        return false;
    }
    return true;
}

} // namespace wekde
