#include "MprisMonitor.hpp"

#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusReply>
#include <QDBusVariant>
#include <QImage>
#include <QNetworkReply>
#include <QThreadPool>
#include <QSet>
#include <QUrl>
#include <QDebug>
#include <algorithm>
#include <cmath>

using namespace wekde;

static const char* MPRIS_PREFIX    = "org.mpris.MediaPlayer2.";
static const char* MPRIS_PATH      = "/org/mpris/MediaPlayer2";
static const char* MPRIS_PLAYER_IF = "org.mpris.MediaPlayer2.Player";
static const char* DBUS_PROPS_IF   = "org.freedesktop.DBus.Properties";

int wekde::toPlaybackState(const QString& status) {
    if (status == "Playing") return 1;
    if (status == "Paused") return 2;
    return 0; // Stopped or unknown
}

QString wekde::mapShortcutToMpris(const QString& name) {
    // Lowercase comparison — WE shortcut names are author-chosen and mixed case.
    const QString n = name.toLower();
    // Canonical control names (wallpapers that follow the WE "bplay/bnext/bprev"
    // convention map 1:1).  Plus numeric aliases used by solar system (3662790108)
    // — b11 = next track, b12 = previous track (per project.json:
    // "下一首 Next" / "上一首 Previous" labels).  If more wallpapers show up
    // with different conventions this map grows; unknown names fall through
    // to the scene event bus so scripts can still self-handle them.
    if (n == "bplay" || n == "bplaypause" || n == "bpause" || n == "playpause") return "PlayPause";
    if (n == "bplayonly" || n == "play") return "Play";
    if (n == "bstop" || n == "stop") return "Stop";
    if (n == "bnext" || n == "next" || n == "b11") return "Next";
    if (n == "bprev" || n == "bprevious" || n == "previous" || n == "b12") return "Previous";
    return {};
}

void MprisMonitor::invokePlayer(const QString& method) {
    // Lazy-engage on first use so wallpapers without media-control
    // SceneScripts don't pay the 1Hz position-poll cost. Repeated calls
    // are cheap (ensureEngaged is idempotent).
    ensureEngaged();
    if (method.isEmpty() || m_activeService.isEmpty()) return;
    // Only allow the well-known MPRIS2 Player methods — defense against a
    // compromised scene JS smuggling arbitrary DBus calls through the shim.
    static const QSet<QString> allowed { "PlayPause", "Play", "Pause", "Stop", "Next", "Previous" };
    if (! allowed.contains(method)) {
        qWarning() << "MprisMonitor::invokePlayer: rejecting non-allowlisted method" << method;
        return;
    }
    QDBusMessage msg =
        QDBusMessage::createMethodCall(m_activeService, MPRIS_PATH, MPRIS_PLAYER_IF, method);
    // Async send — we don't need the reply, just the side effect.
    m_sessionBus.asyncCall(msg);
}

bool MprisMonitor::invokeShortcut(const QString& name) {
    QString method = mapShortcutToMpris(name);
    if (method.isEmpty()) return false;
    invokePlayer(method);
    return true;
}

MprisMetadata wekde::parseMprisMetadata(const QVariantMap& meta) {
    MprisMetadata out;
    out.title           = meta.value("xesam:title").toString();
    QStringList artists = meta.value("xesam:artist").toStringList();
    out.artist          = artists.isEmpty() ? QString() : artists.join(", ");
    out.album           = meta.value("xesam:album").toString();
    out.albumArtist     = meta.value("xesam:albumArtist").toStringList().join(", ");
    out.genres          = meta.value("xesam:genre").toStringList().join(", ");
    out.artUrl          = meta.value("mpris:artUrl").toString();
    out.duration        = meta.value("mpris:length", 0).toLongLong() / 1e6; // µs → s
    return out;
}

MprisArtUrlKind wekde::classifyArtUrl(const QString& artUrl) {
    if (artUrl.isEmpty()) return MprisArtUrlKind::Empty;
    QUrl url(artUrl);
    if (url.isLocalFile()) return MprisArtUrlKind::LocalFile;
    if (url.scheme() == "http" || url.scheme() == "https") return MprisArtUrlKind::Http;
    return MprisArtUrlKind::Unknown;
}

MprisMonitor::MprisMonitor(QQuickItem* parent)
    : QQuickItem(parent), m_sessionBus(QDBusConnection::sessionBus()) {
    // Defer all D-Bus watching + position polling to the first time a
    // wallpaper actually uses media controls. Wallpapers that don't call
    // invokeShortcut / invokePlayer (the vast majority) avoid the 1Hz
    // poll + persistent PropertiesChanged subscription. ensureEngaged()
    // takes care of the lazy hook-up when needed.
}

void MprisMonitor::ensureEngaged() {
    if (m_engaged) return;
    if (! m_sessionBus.isConnected()) {
        qWarning("MprisMonitor: cannot connect to session D-Bus");
        return;
    }
    m_engaged = true;

    // Watch for MPRIS player services appearing/disappearing
    m_sessionBus.connect("org.freedesktop.DBus",
                         "/org/freedesktop/DBus",
                         "org.freedesktop.DBus",
                         "NameOwnerChanged",
                         this,
                         SLOT(handleNameOwnerChanged(QString, QString, QString)));

    // Position polling timer (1 Hz while playing)
    m_positionTimer.setInterval(1000);
    connect(&m_positionTimer, &QTimer::timeout, this, &MprisMonitor::pollPosition);

    // Find any already-running player
    findActivePlayer();
}

void MprisMonitor::findActivePlayer() {
    // Async fan-out/fan-in.  Start a new scan generation so any late replies
    // from a previous (now-superseded) scan are ignored — e.g. when an active
    // player vanishes and re-triggers this while an earlier scan is still in
    // flight.
    const quint64 gen = ++m_scanGeneration;
    m_scanPending     = 0;
    m_scanBest.clear();
    m_scanFoundPlaying = false;

    QDBusMessage listMsg = QDBusMessage::createMethodCall(
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames");
    auto* listWatcher = new QDBusPendingCallWatcher(m_sessionBus.asyncCall(listMsg), this);
    connect(listWatcher,
            &QDBusPendingCallWatcher::finished,
            this,
            [this, gen](QDBusPendingCallWatcher* w) {
                w->deleteLater();
                if (gen != m_scanGeneration) return; // superseded by a newer scan
                QDBusPendingReply<QStringList> reply = *w;
                if (! reply.isValid()) return;

                // Collect MPRIS-prefixed names, preserving ListNames order so the
                // first-seen preference (when nothing is "Playing") is stable
                // regardless of async reply arrival order.
                QStringList players;
                for (const QString& name : reply.value()) {
                    if (name.startsWith(MPRIS_PREFIX)) players << name;
                }
                if (players.isEmpty()) return;

                m_scanPending   = players.size();
                m_scanBestIndex = -1;
                for (int i = 0; i < players.size(); ++i) {
                    const QString name = players.at(i);
                    QDBusMessage  statusMsg =
                        QDBusMessage::createMethodCall(name, MPRIS_PATH, DBUS_PROPS_IF, "Get");
                    statusMsg << QString(MPRIS_PLAYER_IF) << QStringLiteral("PlaybackStatus");
                    auto* sw = new QDBusPendingCallWatcher(m_sessionBus.asyncCall(statusMsg), this);
                    connect(sw,
                            &QDBusPendingCallWatcher::finished,
                            this,
                            [this, gen, i, name](QDBusPendingCallWatcher* sw2) {
                                sw2->deleteLater();
                                if (gen != m_scanGeneration) return; // superseded
                                QDBusPendingReply<QVariant> statusReply = *sw2;
                                const bool                  playing     = statusReply.isValid() &&
                                                     statusReply.value().toString() == "Playing";
                                // Match the old synchronous preference exactly: the
                                // lowest-ListNames-index "Playing" player wins; with
                                // nothing playing, the lowest-index player wins. A
                                // playing candidate always beats a non-playing one;
                                // among equal playing-ness, the lower index wins.
                                // Tracking by index keeps this stable no matter what
                                // order the async replies arrive in.
                                const bool better =
                                    m_scanBestIndex < 0 || (playing && ! m_scanFoundPlaying) ||
                                    (playing == m_scanFoundPlaying && i < m_scanBestIndex);
                                if (better) {
                                    m_scanBestIndex    = i;
                                    m_scanBest         = name;
                                    m_scanFoundPlaying = playing;
                                }

                                if (--m_scanPending <= 0 && ! m_scanBest.isEmpty()) {
                                    connectToPlayer(m_scanBest);
                                }
                            });
                }
            });
}

void MprisMonitor::connectToPlayer(const QString& service) {
    if (m_activeService == service) return;
    disconnectFromPlayer();

    m_activeService = service;
    m_sessionBus.connect(service,
                         MPRIS_PATH,
                         DBUS_PROPS_IF,
                         "PropertiesChanged",
                         this,
                         SLOT(handlePropertiesChanged(QString, QVariantMap, QStringList)));

    m_enabled = true;
    emit enabledChanged(true);

    fetchAllProperties();
    qDebug() << "MprisMonitor: connected to" << service;
}

void MprisMonitor::disconnectFromPlayer() {
    if (m_activeService.isEmpty()) return;
    m_sessionBus.disconnect(m_activeService,
                            MPRIS_PATH,
                            DBUS_PROPS_IF,
                            "PropertiesChanged",
                            this,
                            SLOT(handlePropertiesChanged(QString, QVariantMap, QStringList)));
    m_activeService.clear();
    m_positionTimer.stop();
    // Reset the art-URL dedup tracker. Without this, reconnecting to a
    // different MPRIS player whose first art URL happens to match the
    // previous player's m_lastArtUrl silently dedups and the thumbnail
    // never updates. m_lastArtUrl + m_artUrlEverProcessed are bound to
    // the previous connection's lifetime, not the wallpaper's.
    m_lastArtUrl.clear();
    m_artUrlEverProcessed = false;
    if (m_enabled) {
        m_enabled = false;
        emit enabledChanged(false);
    }
}

void MprisMonitor::applyPlaybackStatus(const QString& status) {
    int state = toPlaybackState(status);
    if (state != m_playbackState) {
        m_playbackState = state;
        emit playbackStateChanged(state);
        if (state == 1)
            m_positionTimer.start();
        else
            m_positionTimer.stop();
    }
}

void MprisMonitor::applyMetadata(const QVariantMap& meta) {
    auto md    = parseMprisMetadata(meta);
    m_duration = md.duration;
    emit propertiesChanged(md.title, md.artist, md.album, md.albumArtist, md.genres, m_duration);
    if (md.artUrl != m_lastArtUrl || ! m_artUrlEverProcessed) {
        m_lastArtUrl          = md.artUrl;
        m_artUrlEverProcessed = true;
        processArtUrl(md.artUrl);
    }
}

// Issue an async org.freedesktop.DBus.Properties.Get(MPRIS_PLAYER_IF, prop)
// against the active player. The reply is delivered on a later event-loop turn
// (so a hung player never blocks the GUI thread) and routed to `onReply` with
// the unwrapped property QVariant. Returns the watcher (parented to `this`, so
// it self-cleans) or nullptr when there's no active service.
template<class Fn>
static QDBusPendingCallWatcher*
asyncGetProperty(QObject* parent, QDBusConnection& bus, const QString& service, const QString& path,
                 const QString& iface, const QString& prop, Fn onReply) {
    if (service.isEmpty()) return nullptr;
    QDBusMessage msg = QDBusMessage::createMethodCall(service, path, DBUS_PROPS_IF, "Get");
    msg << iface << prop;
    auto* watcher = new QDBusPendingCallWatcher(bus.asyncCall(msg), parent);
    QObject::connect(
        watcher, &QDBusPendingCallWatcher::finished, parent, [onReply](QDBusPendingCallWatcher* w) {
            QDBusPendingReply<QVariant> reply = *w;
            if (reply.isValid()) onReply(reply.value());
            w->deleteLater();
        });
    return watcher;
}

void MprisMonitor::fetchAllProperties() {
    const QString service = m_activeService;

    // PlaybackStatus — async; the reply may arrive after a later event-loop turn.
    asyncGetProperty(this,
                     m_sessionBus,
                     service,
                     MPRIS_PATH,
                     MPRIS_PLAYER_IF,
                     "PlaybackStatus",
                     [this](const QVariant& v) {
                         applyPlaybackStatus(v.toString());
                     });

    // Metadata — async; unmarshal the QDBusArgument before handing to the
    // shared applyMetadata helper.
    asyncGetProperty(this,
                     m_sessionBus,
                     service,
                     MPRIS_PATH,
                     MPRIS_PLAYER_IF,
                     "Metadata",
                     [this](const QVariant& v) {
                         applyMetadata(qdbus_cast<QVariantMap>(v.value<QDBusArgument>()));
                     });

    // Position — async; emits its own timelineChanged when it lands.
    asyncGetProperty(this,
                     m_sessionBus,
                     service,
                     MPRIS_PATH,
                     MPRIS_PLAYER_IF,
                     "Position",
                     [this](const QVariant& v) {
                         m_lastPosition = v.toLongLong() / 1e6;
                         emit timelineChanged(m_lastPosition, m_duration, m_playbackState);
                     });
}

void MprisMonitor::handlePropertiesChanged(const QString& interface, const QVariantMap& changed,
                                           const QStringList& /*invalidated*/) {
    if (interface != MPRIS_PLAYER_IF) return;

    if (changed.contains("PlaybackStatus")) {
        applyPlaybackStatus(changed["PlaybackStatus"].toString());
    }

    if (changed.contains("Metadata")) {
        // handlePropertiesChanged may be invoked from tests with a plain
        // QVariantMap wrapper (not a real QDBusArgument).  Handle both: if it's
        // a QDBusArgument, unmarshal via qdbus_cast; otherwise take the map
        // directly.  The unmarshalled map is then handed to applyMetadata,
        // shared with the fetchAllProperties async-reply path.
        QVariantMap     meta;
        const QVariant& v = changed["Metadata"];
        if (v.canConvert<QDBusArgument>()) {
            meta = qdbus_cast<QVariantMap>(v.value<QDBusArgument>());
        }
        if (meta.isEmpty()) {
            meta = v.toMap();
        }
        applyMetadata(meta);
    }
}

void MprisMonitor::handleNameOwnerChanged(const QString& name, const QString& oldOwner,
                                          const QString& newOwner) {
    Q_UNUSED(oldOwner)
    if (! name.startsWith(MPRIS_PREFIX)) return;

    if (! newOwner.isEmpty() && m_activeService.isEmpty()) {
        // New player appeared and we have no active one
        connectToPlayer(name);
    } else if (name == m_activeService && newOwner.isEmpty()) {
        // Our active player vanished — try to find another
        disconnectFromPlayer();
        findActivePlayer();
    }
}

void MprisMonitor::pollPosition() {
    if (m_activeService.isEmpty()) return;
    // Skip if a previous poll is still in flight — a slow/hung player must not
    // let the 1Hz timer pile up overlapping Get(Position) calls.
    if (m_pollPending) return;

    QDBusMessage msg =
        QDBusMessage::createMethodCall(m_activeService, MPRIS_PATH, DBUS_PROPS_IF, "Get");
    msg << QString(MPRIS_PLAYER_IF) << QStringLiteral("Position");
    m_pollPending = true;
    auto* watcher = new QDBusPendingCallWatcher(m_sessionBus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher* w) {
        m_pollPending                     = false;
        QDBusPendingReply<QVariant> reply = *w;
        if (reply.isValid()) {
            m_lastPosition = reply.value().toLongLong() / 1e6;
            emit timelineChanged(m_lastPosition, m_duration, m_playbackState);
        }
        w->deleteLater();
    });
}

void MprisMonitor::processArtUrl(const QString& artUrl) {
    switch (classifyArtUrl(artUrl)) {
    case MprisArtUrlKind::Empty: emit thumbnailChanged(false, {}); return;
    case MprisArtUrlKind::LocalFile: {
        const QString localPath = QUrl(artUrl).toLocalFile();
        const quint64 gen       = ++m_artGeneration;
        QThreadPool::globalInstance()->start([this, localPath, gen]() {
            QImage img(localPath); // decode off the compositor thread
            if (img.isNull()) {
                QMetaObject::invokeMethod(
                    this,
                    [this, gen]() {
                        if (gen != m_artGeneration) return; // superseded by a newer cover
                        emit thumbnailChanged(false, {});
                    },
                    Qt::QueuedConnection);
                return;
            }
            // extractDominantColors touches no `this`/shared state — safe here.
            const QVariantList colors = wekde::extractDominantColors(img);
            QMetaObject::invokeMethod(
                this,
                [this, gen, colors]() {
                    if (gen != m_artGeneration) return; // superseded by a newer cover
                    emit thumbnailChanged(true, colors);
                },
                Qt::QueuedConnection);
        });
        return;
    }
    case MprisArtUrlKind::Http: {
        QNetworkReply* reply = m_nam.get(QNetworkRequest(QUrl(artUrl)));
        connect(reply, &QNetworkReply::finished, this, &MprisMonitor::onArtDownloaded);
        return;
    }
    case MprisArtUrlKind::Unknown: emit thumbnailChanged(false, {}); return;
    }
}

bool wekde::decodeArtReplyBytes(const QByteArray& data, bool networkError,
                                QVariantList& outColors) {
    outColors.clear();
    if (networkError) return false;
    QImage img;
    img.loadFromData(data);
    if (img.isNull()) return false;
    outColors = extractDominantColors(img);
    return true;
}

void MprisMonitor::onArtDownloaded() {
    auto* reply = qobject_cast<QNetworkReply*>(sender());
    if (! reply) return;
    reply->deleteLater();

    QVariantList colors;
    if (decodeArtReplyBytes(reply->readAll(), reply->error() != QNetworkReply::NoError, colors)) {
        emit thumbnailChanged(true, colors);
    } else {
        emit thumbnailChanged(false, {});
    }
}

QVariantList wekde::extractDominantColors(const QImage& img) {
    // Scale to 16x16 for fast color extraction
    QImage small = img.scaled(16, 16, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
                       .convertToFormat(QImage::Format_RGB32);

    // Collect pixels into hue buckets (6 hue × 3 brightness = 18 bins)
    struct Bucket {
        double r { 0 }, g { 0 }, b { 0 };
        int    count { 0 };
    };
    Bucket bins[18];

    for (int y = 0; y < small.height(); y++) {
        for (int x = 0; x < small.width(); x++) {
            QColor c(small.pixelColor(x, y));
            double r = c.redF(), g = c.greenF(), b = c.blueF();
            // Hue bucket (0-5)
            int h       = c.hsvHue(); // 0-359, -1 for achromatic
            int hBucket = (h < 0) ? 0 : (h * 6 / 360);
            hBucket     = std::clamp(hBucket, 0, 5);
            // Brightness bucket (0-2)
            double lum     = 0.299 * r + 0.587 * g + 0.114 * b;
            int    bBucket = (lum < 0.33) ? 0 : (lum < 0.66) ? 1 : 2;
            int    idx     = hBucket * 3 + bBucket;
            bins[idx].r += r;
            bins[idx].g += g;
            bins[idx].b += b;
            bins[idx].count++;
        }
    }

    // Sort by count descending
    int order[18];
    for (int i = 0; i < 18; i++) order[i] = i;
    std::sort(order, order + 18, [&](int a, int b) {
        return bins[a].count > bins[b].count;
    });

    // Top 3 → primary, secondary, tertiary
    auto avgColor = [&](int idx, double out[3]) {
        auto& bin = bins[idx];
        if (bin.count > 0) {
            out[0] = bin.r / bin.count;
            out[1] = bin.g / bin.count;
            out[2] = bin.b / bin.count;
        } else {
            out[0] = out[1] = out[2] = 0;
        }
    };

    double primary[3], secondary[3], tertiary[3];
    avgColor(order[0], primary);
    avgColor(order[1], secondary);
    avgColor(order[2], tertiary);

    // textColor: black or white based on primary luminance
    double primLum = 0.299 * primary[0] + 0.587 * primary[1] + 0.114 * primary[2];
    double text[3] = { primLum > 0.5 ? 0.0 : 1.0,
                       primLum > 0.5 ? 0.0 : 1.0,
                       primLum > 0.5 ? 0.0 : 1.0 };

    // highContrastColor: bucket most distant from primary in RGB space
    double maxDist = 0;
    int    maxIdx  = order[0];
    for (int i = 0; i < 18; i++) {
        if (bins[i].count == 0) continue;
        double cr[3];
        avgColor(i, cr);
        double dr = cr[0] - primary[0], dg = cr[1] - primary[1], db = cr[2] - primary[2];
        double dist = dr * dr + dg * dg + db * db;
        if (dist > maxDist) {
            maxDist = dist;
            maxIdx  = i;
        }
    }
    double contrast[3];
    avgColor(maxIdx, contrast);

    // Pack as flat QVariantList: [r0,g0,b0, r1,g1,b1, ...]
    QVariantList colors;
    for (auto c : { primary, secondary, tertiary, text, contrast }) {
        colors << c[0] << c[1] << c[2];
    }
    return colors;
}
