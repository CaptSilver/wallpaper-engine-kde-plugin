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
    // Bytes freed by the most recent enforceCacheQuota run (0 if last run was
    // a no-op or never ran). UI binds this to render "Last GC: N MB freed".
    Q_PROPERTY(qint64 lastGcBytesFreed READ lastGcBytesFreed NOTIFY lastGcBytesFreedChanged)

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
    // regardless. Call these from the GUI thread only: a requestReadFile job
    // already in flight keeps the allowlist it was dispatched with, so a
    // settings change never retroactively refuses an in-flight read.
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
    // requestDirSize. The allowlist is snapshotted on the CALLING thread at
    // dispatch; canonicalisation, the allowlist test and the size cap all run
    // inside the worker (canonicalisation needs syscalls — not safe on the GUI
    // thread). The async path does NOT bypass the gate. The path delivered in
    // the signal is the path the caller passed (NOT the canonical one), so
    // QML-side waiter maps keyed by the originally-requested path work without
    // an extra round-trip.
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

    // Recursively remove the contents of a directory that is a strict
    // descendant of the user's cache root (wekde::cache_paths::userCacheRoot)
    // — a safety belt against a stray "/" or "/home/<user>" landing in `path`
    // via a misconfigured plugin_info.cache_path. Files that are user state
    // rather than cache (SceneScript localStorage) are kept, along with any
    // directory still holding one. Returns true on success (directory now
    // empty of cache or didn't exist), false on permission error or
    // path-outside-cache violation.
    Q_INVOKABLE bool clearCacheDir(const QString& path);

    // <cacheRoot>/video-thumbs — where generated video thumbnails and their
    // .meta sidecars live. The QML writer and the C++ reaper used to each
    // spell this layout out; this is the one definition. Strips a leading
    // file:// and any trailing slash. Empty in, empty out.
    Q_INVOKABLE static QString videoThumbDir(const QString& cacheRoot);

    // Take the cache ROOT (plugin_info.cache_path), walk its video-thumbs
    // subdirectory, and drop any <hash>.jpg whose <hash>.meta sidecar
    // references a source that is gone for good. "Gone for good" means the
    // file does not exist AND, if it sits under one of the seeded roots, that
    // root is currently visible — a thumbnail whose Steam library is
    // unplugged is kept. Entries without sidecars are KEPT (backwards-safe —
    // pre-feature cache survives). Returns bytes freed. Same isUnderRoot
    // symlink-escape safety as clearCacheDir.
    Q_INVOKABLE qint64 pruneOrphanThumbnails(const QString&     cacheRoot,
                                             const QStringList& installedWallpaperDirs,
                                             const QStringList& videoFolderPaths);

    // Recursively walk each root, sum bytes; if over `quotaBytes`, delete
    // oldest entries (by atime, mtime fallback) until under the cap. Drops
    // matching .meta sidecars alongside their .jpg. Persistent state
    // (SceneScript localStorage) counts toward the total but is never
    // evicted. Throttled to one run per minute (use the *Force overload to
    // skip the throttle for the manual "Run cache GC now" button).
    // quotaBytes == 0 means unlimited (no-op). Returns bytes freed (0 if
    // no-op). Both run on the CALLING thread — from QML prefer
    // requestCacheGc().
    Q_INVOKABLE qint64 enforceCacheQuota(const QStringList& roots, qint64 quotaBytes);
    Q_INVOKABLE qint64 enforceCacheQuotaForce(const QStringList& roots, qint64 quotaBytes);
    qint64             lastGcBytesFreed() const { return m_lastGcBytesFreed; }

    // Startup cache pass — orphan-thumbnail prune followed by LRU quota
    // eviction — dispatched on the thread pool, reporting via
    // cacheGcFinished. The wallpaper item fires this from
    // Component.onCompleted, i.e. on plasmashell's GUI thread: a populated
    // shader cache is hundreds of directories, and stat-walking it inline
    // stalls the whole shell at every login. Throttled to one pass per
    // minute; a throttled call returns without dispatching and without
    // emitting. quotaBytes == 0 skips the eviction half.
    Q_INVOKABLE void requestCacheGc(const QString&     cacheRoot,
                                    const QStringList& installedWallpaperDirs,
                                    const QStringList& videoFolderPaths, qint64 quotaBytes);

    // Atomic JSON write: encode `doc` to UTF-8, write to <path>.tmp, flush,
    // then rename(2) to `path`. Returns false on any failure; the temp file
    // is removed on failure to avoid clutter. Uses no instance state — static
    // so callers (e.g. PlaylistManager::persist) need not construct a throwaway
    // FileHelper (whose ctor mkpaths the wallpaper config dir as a side effect).
    static bool atomicWriteJson(const QString& path, const QJsonDocument& doc);

    // Steam Workshop manifest parsing (Valve KVFormat .acf). Returns a hash
    // of workshop-id -> timeupdated. Fail-soft on missing file, I/O error,
    // or malformed input (returns empty hash). `steamLibraryPath` is the
    // user's Steam library root (e.g. ~/.steam/steam or a custom drive
    // root); we append the relative path to steamapps/workshop/<appid>.acf.
    Q_INVOKABLE QVariantMap readWorkshopManifest(const QString& steamLibraryPath);

    // Read the last_seen_version key from <id>.json (0 if file absent or
    // key not set). Mirror of recordSeenVersion.
    Q_INVOKABLE qint64 seenVersion(const QString& id) const;

    // Write the last_seen_version key into <id>.json (merged with any
    // existing keys via atomicWriteJson). Idempotent; creates the file
    // if absent.
    Q_INVOKABLE void recordSeenVersion(const QString& id, qint64 timeUpdated);

    // Return a map of workshop-id -> last_seen_version covering every
    // <id>.json under the wallpaper config dir. Missing key => entry
    // absent from the map (callers default to 0).
    Q_INVOKABLE QVariantMap allSeenVersions() const;

signals:
    // Emitted when lastGcBytesFreed changes (after every enforceCacheQuota
    // run that actually freed bytes; not emitted for no-op runs that
    // skipped due to under-quota or zero-quota).
    void lastGcBytesFreedChanged();

    void thumbnailReady(const QString& videoPath, const QString& outPath, bool ok);
    void dirSizeReady(const QString& path, qint64 bytes);
    void fileReadReady(const QString& path, const QByteArray& contents, bool ok);
    // Emitted on the GUI thread when a watched wallpaper directory changes.
    // `path` is the parent directory whose contents changed (NOT the subdir
    // that was added/removed — QFileSystemWatcher doesn't expose that).
    void wallpaperDirChanged(const QString& path);

    // Emitted on the GUI thread when a requestCacheGc pass finishes.
    void cacheGcFinished(qint64 prunedBytes, qint64 evictedBytes);

private:
    // The quota sweep with no instance state, so a pool worker can run it.
    // enforceCacheQuotaForce is this plus the m_lastGcBytesFreed bookkeeping.
    static qint64 sweepCacheQuota(const QStringList& roots, qint64 quotaBytes);

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
    // Mutated on the GUI thread only; pool workers get a snapshot taken at
    // dispatch and never read this member.
    QSet<QString> m_readRoots;

    // Lazy-constructed QFileSystemWatcher for wallpaper directories. Parented
    // to this so Qt destroys it with the FileHelper.
    QFileSystemWatcher* m_wallpaperDirWatcher { nullptr };

    // Rolling tally of bytes freed by the most recent enforceCacheQuota
    // run; surfaced as a Q_PROPERTY for the SettingPage "Last GC: N MB
    // freed" readout.
    qint64 m_lastGcBytesFreed { 0 };

    // Cooldown shared by enforceCacheQuota and requestCacheGc. The cost being
    // throttled is the tree walk, not the deletion.
    static constexpr qint64 kGcCooldownMs = 60'000;

    // Monotonic timestamp (msecs since epoch) of the last completed cache
    // walk; the throttle skips runs called < kGcCooldownMs after.
    // qint64{0} sentinel = never ran (always allow first run).
    qint64 m_lastEnforceMs { 0 };
};

} // namespace wekde
