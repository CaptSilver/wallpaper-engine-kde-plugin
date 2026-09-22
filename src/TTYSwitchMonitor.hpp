#pragma once
#include <QQuickItem>
#include <QDBusConnection>
#include <QStringList>
#include <QVariantMap>

namespace wekde
{

// Listens for org.freedesktop.login1.Manager.PrepareForSleep(bool), and
// separately watches our own logind session's Active property for VT
// switches (Ctrl+Alt+Fn away/back, or a display manager's fast user
// switch) -- there is no PrepareForSleep-shaped broadcast for those, so
// Active is the only signal logind offers. The two sources are
// independent and OR'd together into a single ttySwitch(bool) signal.
// The renderer uses this via main.qml's pause-on-suspend chain (alongside
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
    void handleSessionActiveChanged(bool active);
    void handleSessionPropertiesChanged(const QString&     interfaceName,
                                        const QVariantMap& changedProperties,
                                        const QStringList& invalidatedProperties);

private:
    void wireUp(QDBusConnection bus);
    void resolveSessionByPid(QDBusConnection bus);
    void resolveSessionByXdgSessionId(QDBusConnection bus);
    void subscribeToSessionActive(QDBusConnection bus, const QString& sessionPath);
    void updateSleeping();

    bool m_sleeping;
    bool m_suspending;    // from PrepareForSleep
    bool m_sessionActive; // from our logind session's Active property
};

} // namespace wekde