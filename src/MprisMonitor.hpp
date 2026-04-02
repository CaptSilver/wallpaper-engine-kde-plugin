#pragma once
#include <QQuickItem>
#include <QDBusConnection>
#include <QTimer>
#include <QVariantList>
#include <QNetworkAccessManager>

namespace wekde
{

class MprisMonitor : public QQuickItem {
    Q_OBJECT

public:
    MprisMonitor(QQuickItem* parent = nullptr);

signals:
    void playbackStateChanged(int state);   // 0=stopped, 1=playing, 2=paused
    void propertiesChanged(const QString& title, const QString& artist,
                           const QString& albumTitle, const QString& albumArtist,
                           const QString& genres);
    void thumbnailChanged(bool hasThumbnail, const QVariantList& colors);
    void timelineChanged(double position, double duration);
    void enabledChanged(bool enabled);

private slots:
    void handlePropertiesChanged(const QString& interface,
                                 const QVariantMap& changed,
                                 const QStringList& invalidated);
    void handleNameOwnerChanged(const QString& name, const QString& oldOwner,
                                const QString& newOwner);
    void pollPosition();
    void onArtDownloaded();

private:
    void connectToPlayer(const QString& service);
    void disconnectFromPlayer();
    void findActivePlayer();
    void fetchAllProperties();
    void processArtUrl(const QString& artUrl);
    void extractColors(const QImage& img);

    QDBusConnection  m_sessionBus;
    QString          m_activeService;
    QTimer           m_positionTimer;
    double           m_lastPosition { 0 };
    double           m_duration { 0 };
    int              m_playbackState { 0 }; // 0=stopped
    bool             m_enabled { false };
    QString          m_lastArtUrl;

    QNetworkAccessManager m_nam;
};

} // namespace wekde
