#pragma once
#include <QQuickItem>
#include <QDBusConnection>

namespace wekde
{

// Listens for screen-lock / screensaver activation on the session bus and
// forwards the dual-interface ActiveChanged(bool) stream into a single
// Q_PROPERTY(bool active) NOTIFY signal. The renderer consumes this via the
// `background.ok` boolean chain in main.qml to pause-on-lock — alongside
// TTYSwitchMonitor's pause-on-suspend, the focus-window pause, and the
// battery-discharge pause.
//
// Two interfaces are subscribed: org.freedesktop.ScreenSaver (portable
// across compositors) AND org.kde.screensaver (KDE-specific; guaranteed
// under Plasma 6 even when the FDO proxy goes stale). Both route to the
// SAME handleActiveChanged(bool) slot; the state-edge dedupe in the slot
// absorbs the cross-interface double-fire so QML sees one event per real
// lock/unlock.
class ScreenSaverMonitor : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(bool active READ isActive NOTIFY screenSaverActiveChanged)

public:
    ScreenSaverMonitor(QQuickItem* parent = nullptr);
    // Injectable-bus overload for tests: keeps the slot reachable without a
    // live session D-Bus.  Production constructs through the default ctor;
    // tests pass QDBusConnection::sessionBus() if a real bus is reachable
    // or skip the connect path entirely (the unit suite exercises the slot
    // directly per feedback_distrobox_dbus_launch_missing — neither
    // dbus-launch nor dbus-run-session ship in the Bazzite Fedora toolbox).
    ScreenSaverMonitor(QDBusConnection bus, QQuickItem* parent);

    bool isActive() const { return m_active; }

signals:
    void screenSaverActiveChanged(bool active);

public slots:
    void handleActiveChanged(bool active);

private:
    void wireUp(QDBusConnection bus);
    bool m_active;
};

} // namespace wekde
