#pragma once
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QVariantList>
#include <QSet>
#include <QMutex>
#include <QJsonDocument>

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

private:
    QString configDir() const;
    QString wallpaperConfigDir() const;
    QString wallpaperConfigFile(const QString& id) const;

    QMutex        m_inflightMutex;
    QSet<QString> m_inflight; // key = videoPath
};

} // namespace wekde
