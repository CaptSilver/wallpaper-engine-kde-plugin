#include "ScreenSaverMonitor.hpp"
#include <QDebug>

using namespace wekde;

ScreenSaverMonitor::ScreenSaverMonitor(QQuickItem* parent)
    : QQuickItem(parent), m_active(false) {
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
}

void ScreenSaverMonitor::handleActiveChanged(bool active) {
    if (m_active != active) {
        m_active = active;
        emit screenSaverActiveChanged(active);
    }
}
