#include "TTYSwitchMonitor.hpp"
#include <QDebug>

using namespace wekde;

TTYSwitchMonitor::TTYSwitchMonitor(QQuickItem* parent): QQuickItem(parent), m_sleeping(false) {
    // Pause-on-suspend is a polish feature — degrading to "no TTY/suspend
    // pause" is fine in toolbox / sandbox / minimal environments. Don't
    // qFatal; that takes down plasmashell with us.
    QDBusConnection systemBus = QDBusConnection::systemBus();
    if (! systemBus.isConnected()) {
        qWarning("wekde::TTYSwitchMonitor: system D-Bus unavailable; "
                 "pause-on-suspend disabled");
        return;
    }
    wireUp(systemBus);
}

TTYSwitchMonitor::TTYSwitchMonitor(QDBusConnection bus, QQuickItem* parent)
    : QQuickItem(parent), m_sleeping(false) {
    if (bus.isConnected()) wireUp(bus);
}

void TTYSwitchMonitor::wireUp(QDBusConnection bus) {
    bool connected = bus.connect("org.freedesktop.login1",
                                 "/org/freedesktop/login1",
                                 "org.freedesktop.login1.Manager",
                                 "PrepareForSleep",
                                 this,
                                 SLOT(handlePrepareForSleep(bool)));
    if (! connected) {
        qWarning("wekde::TTYSwitchMonitor: failed to connect to "
                 "PrepareForSleep signal; pause-on-suspend disabled");
    }
}

void TTYSwitchMonitor::handlePrepareForSleep(bool sleep) {
    if (m_sleeping != sleep) {
        m_sleeping = sleep;
        emit ttySwitch(sleep);
    }
}
