#pragma once
#include <QQuickItem>
#include <QDBusConnection>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QPointer>
#include <QSet>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QNetworkAccessManager>

// Forward declaration in the global namespace so the friend declaration
// inside wekde::MprisMonitor (below) refers to the global ::TestMprisColors
// rather than wekde::TestMprisColors. The test fixture lives outside
// the wekde namespace.
class TestMprisColors;

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
    // Test seam: lets tst_mpriscolors invoke the private disconnectFromPlayer
    // and applyPlaybackStatus without promoting them to public/Q_INVOKABLE
    // (production has no external caller for either; the slots are only
    // reached through D-Bus signal dispatch). ::TestMprisColors lives in the
    // global namespace (see forward decl above).
    friend class ::TestMprisColors;

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

    // Start watching D-Bus for MPRIS player services + poll position.
    // Call from QML when the wallpaper subscribes to media-info signals
    // (propertiesChanged / playbackStateChanged / timelineChanged /
    // thumbnailChanged). Wallpapers that never touch media controls
    // skip this and avoid the 1Hz poll + persistent subscription.
    // Idempotent.
    Q_INVOKABLE void engage() { ensureEngaged(); }

signals:
    void playbackStateChanged(int state); // 0=stopped, 1=playing, 2=paused
    // `duration` carries the most recent known track length so SceneScript
    // can read mediaPropertiesChanged event.duration alongside title/artist
    // (some WE scripts read duration from this event rather than waiting for
    // a separate timeline tick).  0.0 when unknown.
    void propertiesChanged(const QString& title, const QString& artist, const QString& albumTitle,
                           const QString& albumArtist, const QString& genres, double duration);
    void thumbnailChanged(bool hasThumbnail, const QVariantList& colors);
    // `state` mirrors playbackStateChanged (0=stopped 1=playing 2=paused) so
    // SceneScript can read event.state from the timeline event without
    // synchronizing against the separate playbackStateChanged signal.
    void timelineChanged(double position, double duration, int state);
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
    // Apply a PlaybackStatus string (the value of the "PlaybackStatus" MPRIS
    // property): map to the int state, emit playbackStateChanged on a real
    // transition, and start/stop the 1Hz position poll. Shared by the
    // fetchAllProperties async reply path and handlePropertiesChanged. Pure
    // side-effect on member state + signals; no DBus I/O.
    void applyPlaybackStatus(const QString& status);
    // Apply an already-unmarshalled "Metadata" QVariantMap: parse it, cache
    // the duration, emit propertiesChanged, and (de-duplicated on artUrl)
    // kick off art processing. Takes a plain QVariantMap so both the async
    // reply path (which unmarshals the QDBusArgument first) and the
    // PropertiesChanged path (which keeps its test-friendly fallback) can
    // share the body. No DBus I/O.
    void applyMetadata(const QVariantMap& meta);
    // Idempotent: subscribe to NameOwnerChanged + scan for an active
    // MPRIS player. Called lazily on the first invokePlayer /
    // invokeShortcut so wallpapers that never touch media controls
    // don't pay the 1Hz position-poll cost. Tests can force-engage by
    // calling either Q_INVOKABLE.
    void ensureEngaged();

    QDBusConnection m_sessionBus;
    QString         m_activeService;
    QTimer          m_positionTimer;
    double          m_lastPosition { 0 };
    double          m_duration { 0 };
    int             m_playbackState { 0 }; // 0=stopped
    bool            m_enabled { false };
    bool            m_engaged { false }; // true once D-Bus watch started
    QString         m_lastArtUrl;
    bool            m_artUrlEverProcessed { false };
    // Bumped on every art dispatch. An off-thread LocalFile decode captures the
    // value and drops its result on the GUI-thread emit if the generation
    // advanced — so a slow decode of a previous cover can't overwrite the newer
    // one's colors. Mirrors m_scanGeneration.
    quint64 m_artGeneration { 0 };

    // Async D-Bus state. All reads (position poll, the findActivePlayer scan,
    // and fetchAllProperties) now go through QDBusConnection::asyncCall +
    // QDBusPendingCallWatcher so a hung media player can never block the GUI
    // (plasmashell compositor) thread for the 25s D-Bus default.
    //
    // m_pollPending guards against piling up overlapping position polls: the
    // 1Hz timer must not fan out a new Get(Position) while a previous one is
    // still in flight against a slow player.
    bool m_pollPending { false };
    // findActivePlayer fan-out/fan-in: m_scanGeneration bumps on every scan so
    // late replies from a superseded scan are ignored; m_scanPending counts the
    // per-service PlaybackStatus probes still outstanding; m_scanBest holds the
    // first-seen (or first "Playing") candidate; m_scanFoundPlaying short-
    // circuits the rest once a playing player is seen.
    quint64 m_scanGeneration { 0 };
    int     m_scanPending { 0 };
    QString m_scanBest;
    int     m_scanBestIndex { -1 };
    bool    m_scanFoundPlaying { false };

    QNetworkAccessManager m_nam;
};

} // namespace wekde
