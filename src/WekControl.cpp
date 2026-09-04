#include "WekControl.hpp"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDebug>
#include <QMetaObject>
#include <QVariant>

namespace wekde
{

namespace
{
constexpr const char* kServiceName = "com.github.captsilver.WallpaperEngine";
constexpr const char* kObjectPath  = "/WallpaperEngine";
} // namespace

WekControl::WekControl(QObject* parent): QObject(parent), m_bus(QDBusConnection::sessionBus()) {
    // Lazy-register at construction: silent fail on multi-monitor secondaries
    // (a sibling plasmoid in this process already exports the object path, so
    // this one goes silent — the slot bodies still no-op safely without
    // registration).  Also silent on environments without a session bus
    // (Bazzite distrobox).
    if (m_bus.isConnected()) registerOn(m_bus);
}

WekControl::WekControl(QObject* parent, QDBusConnection bus)
    : QObject(parent), m_bus(std::move(bus)) {}

WekControl::~WekControl() {
    // Release only what this instance actually took.  The name belongs to the
    // shared session-bus connection, so a non-owning secondary that released
    // it would kill the owner's control surface; Qt unregisters our own
    // exported node on QObject destruction anyway.
    if (m_registered) m_bus.unregisterService(kServiceName);
}

WekControl* WekControl::registerOnSessionBus(QObject* parent) {
    auto bus = QDBusConnection::sessionBus();
    if (! bus.isConnected()) {
        qWarning("wek-dbus: session bus unavailable; control disabled");
        return nullptr;
    }
    auto* control = new WekControl(parent, bus);
    if (! control->registerOn(control->m_bus)) {
        delete control;
        return nullptr;
    }
    return control;
}

WekControl* WekControl::registerOnConnection(QDBusConnection bus, QObject* parent) {
    auto* control = new WekControl(parent, std::move(bus));
    if (! control->registerOn(control->m_bus)) {
        delete control;
        return nullptr;
    }
    return control;
}

bool WekControl::registerOn(QDBusConnection& bus) {
    // Object path first, name second.  A bus name belongs to the connection,
    // not to us: on multi-monitor every plasmoid lives in one plasmashell
    // process on one shared session-bus connection, so a second instance's
    // registerService would succeed with ALREADY_OWNER and its rollback would
    // release the name the first instance is serving.  Claiming the object
    // path first makes the in-process rival fail here instead, with nothing
    // to roll back.
    if (! bus.registerObject(kObjectPath,
                             this,
                             QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals)) {
        qWarning("wek-dbus: cannot export /WallpaperEngine (another instance in this "
                 "process owns it, or the bus is down); this instance will not own the "
                 "D-Bus surface");
        return false;
    }
    if (! bus.registerService(kServiceName)) {
        // A different process owns the name. Drop the node we just exported —
        // safe because this instance is the one that took it.
        qWarning("wek-dbus: service already registered by another process; this "
                 "instance will not own the D-Bus surface");
        bus.unregisterObject(kObjectPath);
        return false;
    }
    m_registered = true;
    return true;
}

void WekControl::setPlaylistController(QObject* controller) { m_controller = controller; }

// -- Playlist navigation --

void WekControl::Next() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "next", Qt::QueuedConnection);
}
void WekControl::Previous() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "previous", Qt::QueuedConnection);
}
void WekControl::Pause() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "pause", Qt::QueuedConnection);
}
void WekControl::Resume() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "resume", Qt::QueuedConnection);
}
void WekControl::Toggle() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "togglePause", Qt::QueuedConnection);
}

// -- Audio --

void WekControl::Mute() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "mute", Qt::QueuedConnection);
}
void WekControl::Unmute() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "unmute", Qt::QueuedConnection);
}
void WekControl::ToggleMute() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "toggleMute", Qt::QueuedConnection);
}

// -- Activation --

void WekControl::ActivatePlaylist(const QString& id) {
    if (! m_controller) return;
    QMetaObject::invokeMethod(
        m_controller, "activatePlaylistById", Qt::QueuedConnection, Q_ARG(QString, id));
}
void WekControl::Reload() {
    if (! m_controller) return;
    QMetaObject::invokeMethod(m_controller, "reload", Qt::QueuedConnection);
}

// -- Query (sync) --

QString WekControl::CurrentWorkshopId() const {
    if (! m_controller) return {};
    QVariant v;
    QMetaObject::invokeMethod(
        m_controller, "currentWorkshopId", Qt::DirectConnection, Q_RETURN_ARG(QVariant, v));
    return v.toString();
}
QString WekControl::CurrentPlaylistId() const {
    if (! m_controller) return {};
    QVariant v;
    QMetaObject::invokeMethod(
        m_controller, "currentPlaylistId", Qt::DirectConnection, Q_RETURN_ARG(QVariant, v));
    return v.toString();
}
int WekControl::CurrentItemIndex() const {
    if (! m_controller) return -1;
    QVariant v;
    QMetaObject::invokeMethod(
        m_controller, "currentItemIndex", Qt::DirectConnection, Q_RETURN_ARG(QVariant, v));
    bool      ok  = false;
    const int idx = v.toInt(&ok);
    return ok ? idx : -1;
}

// -- Signal bridge from QML --

void WekControl::emitWallpaperChanged(const QString& workshopId, const QString& playlistId) {
    emit WallpaperChanged(workshopId, playlistId);
}

} // namespace wekde
