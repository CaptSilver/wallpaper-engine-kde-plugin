#pragma once
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QVariantList>
#include <QSet>
#include <QMutex>
#include <QJsonDocument>
#include <QThreadPool>

class QFileSystemWatcher;

namespace wekde
{

class FileHelper : public QObject {
    Q_OBJECT

public:
    explicit FileHelper(QObject* parent = nullptr);
    virtual ~FileHelper();

    // File operations
    Q_INVOKABLE QByteArray readFile(const QString& path);
    Q_INVOKABLE QString    qwebChannelSource();
    Q_INVOKABLE QString    patchedHtml(const QString& path);

    // Caller-side allowlist for paths readFile() will accept. QML registers
    // the configured Steam library + the cache + any extra roots (video
    // folder, future plugin dirs) at startup and on each settings change.
    // Roots are canonicalised on insert (rejected if non-existent). readFile
    // canonicalises its argument and accepts iff the canonical form is the
    // root itself or a descendant. Empty allowlist => permissive back-compat
    // (default-installed plugin with no settings configured keeps today's
    // behaviour). The 64 MiB size cap applies in BOTH modes — pathological
    // inputs (a wallpaper symlink to /dev/zero via FUSE) are refused
    // regardless.
    Q_INVOKABLE void addReadRoot(const QString& path);
    Q_INVOKABLE void clearReadRoots();

    // Maximum bytes readFile will return. Larger files yield an empty
    // QByteArray + qWarning. 64 MiB is a generous ceiling for project.json
    // (~10 KB typical, a few MB for fat puppet definitions) while defeating
    // GB-scale DoS reads of /dev/zero or a sparse file.
    static constexpr qint64 kMaxReadSize = 64LL * 1024 * 1024;
    // Synchronous, recursive directory byte total. `depth` semantics:
    //   depth <= 0  => UNLIMITED recursion (historical sentinel — note this is the
    //                  OPPOSITE of "current dir only"; kept for the public contract);
    //   depth == 1  => top-level files only;
    //   depth == N  => files up to N directory levels below `path`.
    // Hidden (dotfile) bytes ARE counted. Runs on the CALLING thread — for the
    // GUI/QML thread prefer requestDirSize() on large trees.
    Q_INVOKABLE qint64 getDirSize(const QString& path, int depth = 3);
    // Asynchronous getDirSize: dispatches the (pure) walk on QThreadPool and emits
    // dirSizeReady(path, bytes) on the GUI thread when done, so a QML cache-size
    // readout never blocks the compositor on a multi-GB tree. Mirrors the
    // generateThumbnail async idiom.
    Q_INVOKABLE void         requestDirSize(const QString& path, int depth = 3);
    Q_INVOKABLE QVariantMap  getFolderList(const QString& path, const QVariantMap& opt = {});
    Q_INVOKABLE QVariantList scanVideoFolder(const QString& path);

    // Wallpaper config operations
    Q_INVOKABLE QVariantMap  readWallpaperConfig(const QString& id);
    Q_INVOKABLE void         writeWallpaperConfig(const QString& id, const QVariantMap& changed);
    Q_INVOKABLE void         resetWallpaperConfig(const QString& id);
    Q_INVOKABLE QVariantList readActiveBindings(const QString& id);

    // Asynchronous thumbnail generation. Submits work to QThreadPool and emits
    // thumbnailReady when done. Concurrent requests for the same videoPath are
    // coalesced — only one libmpv grab runs at a time per input.
    Q_INVOKABLE void generateThumbnail(const QString& videoPath, const QString& outPath,
                                       double atSeconds);

    // Asynchronous readFile: dispatches the canonicalise + allowlist + read off
    // the GUI thread on the per-instance QThreadPool and emits
    // fileReadReady(path, contents, ok) on the GUI thread. Mirrors
    // requestDirSize. ALL allowlist + size-cap checks run inside the worker
    // thread (canonicalisation needs syscalls — not safe on GUI thread); the
    // async path does NOT bypass the gate. The path delivered in the signal is
    // the path the caller passed (NOT the canonical one), so QML-side waiter
    // maps keyed by the originally-requested path work without an extra
    // round-trip.
    Q_INVOKABLE void requestReadFile(const QString& path);

    // Wallpaper directory watcher. Lazy-constructs a QFileSystemWatcher and
    // attaches `path` (intended to be a top-level workshop directory, not each
    // wallpaper subdir — inotify slot budget). A directoryChanged event on
    // any watched dir emits wallpaperDirChanged(path) on the GUI thread.
    // QML-side WallpaperListModel debounces 500 ms (Steam's atomic-rename
    // download generates 2-3 events per subscribe) then calls refresh().
    // addPath() is idempotent — re-adding the same path is a no-op via Qt's
    // own dedup. On unsupported filesystems (NFS / FUSE / sshfs) Qt logs a
    // warning and the watcher silently fails; the manual Refresh button +
    // 10 s safety-net Timer remain as fallback.
    Q_INVOKABLE void watchWallpaperDir(const QString& path);
    // Remove every watched wallpaper directory. Called by QML when the
    // workshopDirs list changes (settings widen/narrow) so stale watchers
    // don't accumulate.
    Q_INVOKABLE void unwatchAllWallpaperDirs();

    // Recursively remove the contents of a directory under the user's cache
    // root (QStandardPaths::CacheLocation). Refuses paths outside the cache
    // root — a safety belt against a stray "/" or "/home/<user>" landing
    // in `path` via a misconfigured plugin_info.cache_path. Returns true on
    // success (directory now empty or didn't exist), false on permission
    // error or path-outside-cache violation.
    Q_INVOKABLE bool clearCacheDir(const QString& path);

    // Atomic JSON write: encode `doc` to UTF-8, write to <path>.tmp, flush,
    // then rename(2) to `path`. Returns false on any failure; the temp file
    // is removed on failure to avoid clutter. Uses no instance state — static
    // so callers (e.g. PlaylistManager::persist) need not construct a throwaway
    // FileHelper (whose ctor mkpaths the wallpaper config dir as a side effect).
    static bool atomicWriteJson(const QString& path, const QJsonDocument& doc);

signals:
    void thumbnailReady(const QString& videoPath, const QString& outPath, bool ok);
    void dirSizeReady(const QString& path, qint64 bytes);
    void fileReadReady(const QString& path, const QByteArray& contents, bool ok);
    // Emitted on the GUI thread when a watched wallpaper directory changes.
    // `path` is the parent directory whose contents changed (NOT the subdir
    // that was added/removed — QFileSystemWatcher doesn't expose that).
    void wallpaperDirChanged(const QString& path);

private:
    QString configDir() const;
    QString wallpaperConfigDir() const;
    QString wallpaperConfigFile(const QString& id) const;

    QMutex        m_inflightMutex;
    QSet<QString> m_inflight; // key = videoPath

    // Per-instance pool so the dtor can waitForDone() and guarantee no
    // background task is touching *this* (m_inflightMutex or, via
    // QMetaObject::invokeMethod, the QObject d_ptr) after destruction.
    // Plasma can tear FileHelper down mid-grab on wallpaper switch — the
    // global pool offers no such handle. Worst-case dtor block is the
    // current libmpv thumbnail timeout (~3s).
    QThreadPool m_pool;

    // Canonicalised allowlist; seeded from QML via addReadRoot. Empty
    // => permissive (back-compat). See readFile body for the check.
    QSet<QString> m_readRoots;

    // Lazy-constructed QFileSystemWatcher for wallpaper directories. Parented
    // to this so Qt destroys it with the FileHelper.
    QFileSystemWatcher* m_wallpaperDirWatcher { nullptr };
};

} // namespace wekde
