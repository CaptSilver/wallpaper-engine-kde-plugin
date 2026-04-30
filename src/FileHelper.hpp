#pragma once
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QVariantList>
#include <QSet>
#include <QMutex>

namespace wekde
{

class FileHelper : public QObject {
    Q_OBJECT

public:
    explicit FileHelper(QObject* parent = nullptr);
    virtual ~FileHelper();

    // File operations
    Q_INVOKABLE QByteArray   readFile(const QString& path);
    Q_INVOKABLE QString      qwebChannelSource();
    Q_INVOKABLE QString      patchedHtml(const QString& path);
    Q_INVOKABLE qint64       getDirSize(const QString& path, int depth = 3);
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

signals:
    void thumbnailReady(const QString& videoPath, const QString& outPath, bool ok);

private:
    QString configDir() const;
    QString wallpaperConfigDir() const;
    QString wallpaperConfigFile(const QString& id) const;

    QMutex        m_inflightMutex;
    QSet<QString> m_inflight; // key = videoPath
};

} // namespace wekde
