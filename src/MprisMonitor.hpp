#pragma once
#include <QQuickItem>
#include <QDBusConnection>
#include <QTimer>
#include <QVariantList>
#include <QNetworkAccessManager>

namespace wekde
{

// Extract dominant colors from an image. Returns flat QVariantList of 15 floats:
// [primaryR,G,B, secondaryR,G,B, tertiaryR,G,B, textR,G,B, contrastR,G,B]
// All values in 0-1 range. Pure function, no Qt Quick dependency — testable.
QVariantList extractDominantColors(const QImage& img);

// MPRIS metadata extracted from a QVariantMap (the "Metadata" dbus property).
// Title/artist/album/albumArtist/genres are joined strings; duration is seconds.
// Pure helper; lives outside the QObject so it can be unit-tested without DBus.
struct MprisMetadata {
    QString title;
    QString artist;
    QString album;
    QString albumArtist;
    QString genres;
    QString artUrl;
    double  duration { 0 };
};
MprisMetadata parseMprisMetadata(const QVariantMap& meta);

// Classify an art URL into categories the monitor handles differently.
enum class MprisArtUrlKind
{
    Empty,
    LocalFile,
    Http,
    Unknown
};
MprisArtUrlKind classifyArtUrl(const QString& artUrl);

// Convert MPRIS PlaybackStatus string to the int state the QML layer expects.
// 0 = stopped, 1 = playing, 2 = paused, 0 for anything else.
int toPlaybackState(const QString& status);

// Map a SceneScript user-shortcut name to a standard MPRIS Player method.
// WE wallpaper authors pick arbitrary names (solar's `b11`/`b12`/`bplay`,
// generic `bnext`/`bprev`/`bplaypause` etc.) — we recognize the common
// media-control patterns and return the MPRIS2 method to invoke.  Empty
// string means the name isn't a recognized media control (caller falls
// back to the scene event bus).  Pure helper so it's unit-testable
// without the DBus session.
QString mapShortcutToMpris(const QString& name);

// Decode the bytes from an MPRIS artUrl HTTP fetch into a flat color list.
// Returns true + fills `outColors` (15 floats) when the payload decoded into
// a valid QImage; returns false + clears `outColors` for network errors,
// empty payloads, and undecodable bytes.  Pure helper — no QObject / DBus
// dependency, directly unit-testable without spinning up QNetworkAccessManager.
bool decodeArtReplyBytes(const QByteArray& data, bool networkError, QVariantList& outColors);

class MprisMonitor : public QQuickItem {
    Q_OBJECT

public:
    MprisMonitor(QQuickItem* parent = nullptr);

    // Invoke a method on the currently-tracked player's MPRIS2 Player
    // interface.  Safe no-op when no player is connected.  Used by Scene.qml
    // to route SceneScript engine.openUserShortcut() calls to media actions.
    Q_INVOKABLE void invokePlayer(const QString& method);
    // Convenience: map a SceneScript usershortcut name to an MPRIS method
    // and invoke if recognized.  Returns true when a media action was sent,
    // false for names the helper doesn't know (Scene.qml can then fall back
    // to logging / scene-bus event).
    Q_INVOKABLE bool invokeShortcut(const QString& name);

    // Currently-tracked MPRIS service name (e.g. "org.mpris.MediaPlayer2.vlc"),
    // or empty when no player is connected.  QML can surface this as a
    // "now tracking <source>" label; tests use it to introspect the state
    // after handleNameOwnerChanged / connectToPlayer runs.
    Q_INVOKABLE QString activeService() const { return m_activeService; }

signals:
    void playbackStateChanged(int state); // 0=stopped, 1=playing, 2=paused
    void propertiesChanged(const QString& title, const QString& artist, const QString& albumTitle,
                           const QString& albumArtist, const QString& genres);
    void thumbnailChanged(bool hasThumbnail, const QVariantList& colors);
    void timelineChanged(double position, double duration);
    void enabledChanged(bool enabled);

private slots:
    void handlePropertiesChanged(const QString& interface, const QVariantMap& changed,
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

    QDBusConnection m_sessionBus;
    QString         m_activeService;
    QTimer          m_positionTimer;
    double          m_lastPosition { 0 };
    double          m_duration { 0 };
    int             m_playbackState { 0 }; // 0=stopped
    bool            m_enabled { false };
    QString         m_lastArtUrl;

    QNetworkAccessManager m_nam;
};

} // namespace wekde
