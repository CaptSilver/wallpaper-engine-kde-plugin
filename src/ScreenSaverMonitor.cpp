#include "ScreenSaverMonitor.hpp"
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDebug>

using namespace wekde;

ScreenSaverMonitor::ScreenSaverMonitor(QQuickItem* parent): QQuickItem(parent), m_active(false) {
    // Pause-on-lock is a polish feature — degrading to "no lock pause" is
    // fine in toolbox / sandbox / minimal environments. Don't qFatal; that
    // would take plasmashell down with us.
    QDBusConnection sessionBus = QDBusConnection::sessionBus();
    if (! sessionBus.isConnected()) {
        qWarning("wekde::ScreenSaverMonitor: session D-Bus unavailable; "
                 "pause-on-lock disabled");
        return;
    }
    wireUp(sessionBus);
}

ScreenSaverMonitor::ScreenSaverMonitor(QDBusConnection bus, QQuickItem* parent)
    : QQuickItem(parent), m_active(false) {
    if (bus.isConnected()) wireUp(bus);
}

void ScreenSaverMonitor::wireUp(QDBusConnection bus) {
    // FreeDesktop interface — portable across compositors that implement
    // the standard org.freedesktop.ScreenSaver. KDE proxies this via
    // kded_screenlocker.
    bool fdo = bus.connect("org.freedesktop.ScreenSaver",
                           "/ScreenSaver",
                           "org.freedesktop.ScreenSaver",
                           "ActiveChanged",
                           this,
                           SLOT(handleActiveChanged(bool)));
    if (! fdo) {
        qWarning("wekde::ScreenSaverMonitor: could not subscribe to "
                 "org.freedesktop.ScreenSaver.ActiveChanged");
    }
    // KDE-specific — guaranteed to fire under Plasma 6 even if the FDO
    // proxy is stale. The state-edge guard in handleActiveChanged dedupes
    // double-emits from the two interfaces.
    bool kde = bus.connect("org.kde.screensaver",
                           "/ScreenSaver",
                           "org.kde.screensaver",
                           "ActiveChanged",
                           this,
                           SLOT(handleActiveChanged(bool)));
    if (! kde) {
        qWarning("wekde::ScreenSaverMonitor: could not subscribe to "
                 "org.kde.screensaver.ActiveChanged (non-KDE session?)");
    }

    // Resync m_active with whatever the lock state already is -- a bare
    // subscription only ever sees the *next* toggle, leaving a monitor
    // built mid-lock wrongly "unlocked" until that toggle happens.
    queryActiveState(bus);

    // kded_screenlocker restarting mid-session drops org.freedesktop.
    // ScreenSaver off the bus and brings it back with a fresh internal
    // state; re-query on every (re)appearance so a restart can't leave
    // m_active stuck on whatever it was before.
    auto* watcher = new QDBusServiceWatcher(QStringLiteral("org.freedesktop.ScreenSaver"),
                                            bus,
                                            QDBusServiceWatcher::WatchForRegistration,
                                            this);
    connect(watcher, &QDBusServiceWatcher::serviceRegistered, this, [this, bus](const QString&) {
        queryActiveState(bus);
    });
}

void ScreenSaverMonitor::queryActiveState(QDBusConnection bus) {
    QDBusMessage getActive = QDBusMessage::createMethodCall(
        "org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver", "GetActive");
    auto* watcher = new QDBusPendingCallWatcher(bus.asyncCall(getActive), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher* w) {
        w->deleteLater();
        QDBusPendingReply<bool> reply = *w;
        if (! reply.isValid()) {
            // No reply -- e.g. GetActive unimplemented, or the service
            // isn't up yet. Leave m_active as-is; the next ActiveChanged
            // signal or service (re)appearance gets another chance.
            qWarning("wekde::ScreenSaverMonitor: GetActive query failed (%s)",
                     qUtf8Printable(reply.error().message()));
            return;
        }
        handleActiveChanged(reply.value());
    });
}

void ScreenSaverMonitor::handleActiveChanged(bool active) {
    if (m_active != active) {
        m_active = active;
        emit screenSaverActiveChanged(active);
    }
}
