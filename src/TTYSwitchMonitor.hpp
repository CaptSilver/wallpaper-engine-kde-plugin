#pragma once
#include <QQuickItem>
#include <QDBusConnection>

namespace wekde
{

// Listens for org.freedesktop.login1.Manager.PrepareForSleep(bool) on the
// system bus and forwards it to a single ttySwitch(bool) signal. The
// renderer uses this via main.qml's pause-on-suspend chain (alongside
// ScreenSaverMonitor's pause-on-lock, the focus-window pause, and the
// battery-discharge pause).
class TTYSwitchMonitor : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(bool sleeping READ isSleeping NOTIFY ttySwitch)

public:
    TTYSwitchMonitor(QQuickItem* parent = nullptr);
    // Injectable-bus overload for tests: keeps the slot reachable without
    // a live system D-Bus.  Production constructs through the default
    // ctor; tests pass either QDBusConnection::systemBus() (if a real bus
    // is reachable) or a synthetic disconnected QDBusConnection so the
    // wireUp branch can be code-pathed without dbus-launch/dbus-run-
    // session (which are absent from the Bazzite Fedora toolbox).
    // Mirrors the ScreenSaverMonitor pattern.
    TTYSwitchMonitor(QDBusConnection bus, QQuickItem* parent);

    bool isSleeping() const { return m_sleeping; }

signals:
    void ttySwitch(bool sleep);

public slots:
    void handlePrepareForSleep(bool sleep);

private:
    void wireUp(QDBusConnection bus);
    bool m_sleeping;
};

} // namespace wekde