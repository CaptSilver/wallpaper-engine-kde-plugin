#include "MprisMonitor.hpp"

#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QImage>
#include <QNetworkReply>
#include <QUrl>
#include <QDebug>
#include <algorithm>
#include <cmath>

using namespace wekde;

static const char* MPRIS_PREFIX    = "org.mpris.MediaPlayer2.";
static const char* MPRIS_PATH      = "/org/mpris/MediaPlayer2";
static const char* MPRIS_PLAYER_IF = "org.mpris.MediaPlayer2.Player";
static const char* DBUS_PROPS_IF   = "org.freedesktop.DBus.Properties";

static int toPlaybackState(const QString& status) {
    if (status == "Playing") return 1;
    if (status == "Paused")  return 2;
    return 0; // Stopped or unknown
}

MprisMonitor::MprisMonitor(QQuickItem* parent)
    : QQuickItem(parent), m_sessionBus(QDBusConnection::sessionBus()) {
    if (!m_sessionBus.isConnected()) {
        qWarning("MprisMonitor: cannot connect to session D-Bus");
        return;
    }

    // Watch for MPRIS player services appearing/disappearing
    m_sessionBus.connect("org.freedesktop.DBus", "/org/freedesktop/DBus",
                         "org.freedesktop.DBus", "NameOwnerChanged",
                         this, SLOT(handleNameOwnerChanged(QString, QString, QString)));

    // Position polling timer (1 Hz while playing)
    m_positionTimer.setInterval(1000);
    connect(&m_positionTimer, &QTimer::timeout, this, &MprisMonitor::pollPosition);

    // Find any already-running player
    findActivePlayer();
}

void MprisMonitor::findActivePlayer() {
    QDBusMessage msg = QDBusMessage::createMethodCall(
        "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "ListNames");
    QDBusReply<QStringList> reply = m_sessionBus.call(msg);
    if (!reply.isValid()) return;

    QString bestService;
    for (const QString& name : reply.value()) {
        if (!name.startsWith(MPRIS_PREFIX)) continue;
        // Prefer a player that's currently playing
        QDBusInterface iface(name, MPRIS_PATH, DBUS_PROPS_IF, m_sessionBus);
        QDBusReply<QVariant> statusReply = iface.call("Get", MPRIS_PLAYER_IF, "PlaybackStatus");
        if (statusReply.isValid() && statusReply.value().toString() == "Playing") {
            bestService = name;
            break;
        }
        if (bestService.isEmpty()) bestService = name;
    }

    if (!bestService.isEmpty()) {
        connectToPlayer(bestService);
    }
}

void MprisMonitor::connectToPlayer(const QString& service) {
    if (m_activeService == service) return;
    disconnectFromPlayer();

    m_activeService = service;
    m_sessionBus.connect(service, MPRIS_PATH, DBUS_PROPS_IF,
                         "PropertiesChanged", this,
                         SLOT(handlePropertiesChanged(QString, QVariantMap, QStringList)));

    m_enabled = true;
    emit enabledChanged(true);

    fetchAllProperties();
    qDebug() << "MprisMonitor: connected to" << service;
}

void MprisMonitor::disconnectFromPlayer() {
    if (m_activeService.isEmpty()) return;
    m_sessionBus.disconnect(m_activeService, MPRIS_PATH, DBUS_PROPS_IF,
                            "PropertiesChanged", this,
                            SLOT(handlePropertiesChanged(QString, QVariantMap, QStringList)));
    m_activeService.clear();
    m_positionTimer.stop();
    if (m_enabled) {
        m_enabled = false;
        emit enabledChanged(false);
    }
}

void MprisMonitor::fetchAllProperties() {
    QDBusInterface iface(m_activeService, MPRIS_PATH, DBUS_PROPS_IF, m_sessionBus);

    // PlaybackStatus
    {
        QDBusReply<QVariant> r = iface.call("Get", MPRIS_PLAYER_IF, "PlaybackStatus");
        if (r.isValid()) {
            int state = toPlaybackState(r.value().toString());
            if (state != m_playbackState) {
                m_playbackState = state;
                emit playbackStateChanged(state);
                if (state == 1) m_positionTimer.start();
                else m_positionTimer.stop();
            }
        }
    }

    // Metadata
    {
        QDBusReply<QVariant> r = iface.call("Get", MPRIS_PLAYER_IF, "Metadata");
        if (r.isValid()) {
            QVariantMap meta = qdbus_cast<QVariantMap>(r.value().value<QDBusArgument>());
            QString title      = meta.value("xesam:title").toString();
            QStringList artists = meta.value("xesam:artist").toStringList();
            QString artist     = artists.isEmpty() ? QString() : artists.join(", ");
            QString album      = meta.value("xesam:album").toString();
            QString albumArtist = meta.value("xesam:albumArtist").toStringList().join(", ");
            QString genres     = meta.value("xesam:genre").toStringList().join(", ");
            m_duration = meta.value("mpris:length", 0).toLongLong() / 1e6; // µs → s

            emit propertiesChanged(title, artist, album, albumArtist, genres);

            QString artUrl = meta.value("mpris:artUrl").toString();
            if (artUrl != m_lastArtUrl) {
                m_lastArtUrl = artUrl;
                processArtUrl(artUrl);
            }
        }
    }

    // Position
    {
        QDBusReply<QVariant> r = iface.call("Get", MPRIS_PLAYER_IF, "Position");
        if (r.isValid()) {
            m_lastPosition = r.value().toLongLong() / 1e6;
            emit timelineChanged(m_lastPosition, m_duration);
        }
    }
}

void MprisMonitor::handlePropertiesChanged(const QString& interface,
                                           const QVariantMap& changed,
                                           const QStringList& /*invalidated*/) {
    if (interface != MPRIS_PLAYER_IF) return;

    if (changed.contains("PlaybackStatus")) {
        int state = toPlaybackState(changed["PlaybackStatus"].toString());
        if (state != m_playbackState) {
            m_playbackState = state;
            emit playbackStateChanged(state);
            if (state == 1) m_positionTimer.start();
            else m_positionTimer.stop();
        }
    }

    if (changed.contains("Metadata")) {
        QVariantMap meta = qdbus_cast<QVariantMap>(changed["Metadata"].value<QDBusArgument>());
        QString title      = meta.value("xesam:title").toString();
        QStringList artists = meta.value("xesam:artist").toStringList();
        QString artist     = artists.isEmpty() ? QString() : artists.join(", ");
        QString album      = meta.value("xesam:album").toString();
        QString albumArtist = meta.value("xesam:albumArtist").toStringList().join(", ");
        QString genres     = meta.value("xesam:genre").toStringList().join(", ");
        m_duration = meta.value("mpris:length", 0).toLongLong() / 1e6;

        emit propertiesChanged(title, artist, album, albumArtist, genres);

        QString artUrl = meta.value("mpris:artUrl").toString();
        if (artUrl != m_lastArtUrl) {
            m_lastArtUrl = artUrl;
            processArtUrl(artUrl);
        }
    }
}

void MprisMonitor::handleNameOwnerChanged(const QString& name, const QString& oldOwner,
                                          const QString& newOwner) {
    if (!name.startsWith(MPRIS_PREFIX)) return;

    if (!newOwner.isEmpty() && m_activeService.isEmpty()) {
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
    QDBusInterface iface(m_activeService, MPRIS_PATH, DBUS_PROPS_IF, m_sessionBus);
    QDBusReply<QVariant> r = iface.call("Get", MPRIS_PLAYER_IF, "Position");
    if (r.isValid()) {
        m_lastPosition = r.value().toLongLong() / 1e6;
        emit timelineChanged(m_lastPosition, m_duration);
    }
}

void MprisMonitor::processArtUrl(const QString& artUrl) {
    if (artUrl.isEmpty()) {
        emit thumbnailChanged(false, {});
        return;
    }

    QUrl url(artUrl);
    if (url.isLocalFile()) {
        QImage img(url.toLocalFile());
        if (!img.isNull()) {
            extractColors(img);
        } else {
            emit thumbnailChanged(false, {});
        }
    } else if (url.scheme() == "http" || url.scheme() == "https") {
        QNetworkReply* reply = m_nam.get(QNetworkRequest(url));
        connect(reply, &QNetworkReply::finished, this, &MprisMonitor::onArtDownloaded);
    } else {
        emit thumbnailChanged(false, {});
    }
}

void MprisMonitor::onArtDownloaded() {
    auto* reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        emit thumbnailChanged(false, {});
        return;
    }

    QImage img;
    img.loadFromData(reply->readAll());
    if (img.isNull()) {
        emit thumbnailChanged(false, {});
        return;
    }
    extractColors(img);
}

QVariantList wekde::extractDominantColors(const QImage& img) {
    // Scale to 16x16 for fast color extraction
    QImage small = img.scaled(16, 16, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
                      .convertToFormat(QImage::Format_RGB32);

    // Collect pixels into hue buckets (6 hue × 3 brightness = 18 bins)
    struct Bucket { double r {0}, g {0}, b {0}; int count {0}; };
    Bucket bins[18];

    for (int y = 0; y < small.height(); y++) {
        for (int x = 0; x < small.width(); x++) {
            QColor c(small.pixelColor(x, y));
            double r = c.redF(), g = c.greenF(), b = c.blueF();
            // Hue bucket (0-5)
            int h = c.hsvHue(); // 0-359, -1 for achromatic
            int hBucket = (h < 0) ? 0 : (h * 6 / 360);
            hBucket = std::clamp(hBucket, 0, 5);
            // Brightness bucket (0-2)
            double lum = 0.299 * r + 0.587 * g + 0.114 * b;
            int bBucket = (lum < 0.33) ? 0 : (lum < 0.66) ? 1 : 2;
            int idx = hBucket * 3 + bBucket;
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
    int maxIdx = order[0];
    for (int i = 0; i < 18; i++) {
        if (bins[i].count == 0) continue;
        double cr[3];
        avgColor(i, cr);
        double dr = cr[0] - primary[0], dg = cr[1] - primary[1], db = cr[2] - primary[2];
        double dist = dr * dr + dg * dg + db * db;
        if (dist > maxDist) { maxDist = dist; maxIdx = i; }
    }
    double contrast[3];
    avgColor(maxIdx, contrast);

    // Pack as flat QVariantList: [r0,g0,b0, r1,g1,b1, ...]
    QVariantList colors;
    for (auto c : {primary, secondary, tertiary, text, contrast}) {
        colors << c[0] << c[1] << c[2];
    }
    return colors;
}

void MprisMonitor::extractColors(const QImage& img) {
    QVariantList colors = wekde::extractDominantColors(img);
    emit thumbnailChanged(true, colors);
}
