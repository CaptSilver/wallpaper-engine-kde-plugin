#include "TTYSwitchMonitor.hpp"
#include <QCoreApplication>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDebug>

using namespace wekde;

TTYSwitchMonitor::TTYSwitchMonitor(QQuickItem* parent)
    : QQuickItem(parent), m_sleeping(false), m_suspending(false), m_sessionActive(true) {
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
    : QQuickItem(parent), m_sleeping(false), m_suspending(false), m_sessionActive(true) {
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

    // Resolve our own logind session so we can watch its Active property for
    // VT switches.
    resolveSessionByPid(bus);
}

void TTYSwitchMonitor::resolveSessionByPid(QDBusConnection bus) {
    // GetSessionByPID's D-Bus signature is (u)->(o) -- a plain uint32 in, an
    // object path out. QCoreApplication::applicationPid() returns qint64;
    // marshaling that directly sends signature 'x', which logind
    // hard-rejects ("Invalid arguments 'x' ... expecting 'u'"). Narrow and
    // wrap explicitly.
    QDBusMessage getSession = QDBusMessage::createMethodCall("org.freedesktop.login1",
                                                             "/org/freedesktop/login1",
                                                             "org.freedesktop.login1.Manager",
                                                             "GetSessionByPID");
    getSession << QVariant::fromValue<quint32>(
        static_cast<quint32>(QCoreApplication::applicationPid()));
    auto* watcher = new QDBusPendingCallWatcher(bus.asyncCall(getSession), this);
    connect(watcher,
            &QDBusPendingCallWatcher::finished,
            this,
            // `bus` (a QDBusConnection) is captured by value, and the body
            // below calls its non-const connect() -- a plain lambda's
            // operator() is const, so that wouldn't compile without
            // `mutable`. This is safe despite looking like it mutates a
            // throwaway copy: QDBusConnection is a thin handle around a
            // shared, refcounted d-pointer, so connect() on any copy
            // registers against the one real bus connection underneath.
            [this, bus](QDBusPendingCallWatcher* w) mutable {
                w->deleteLater();
                QDBusPendingReply<QDBusObjectPath> reply = *w;
                if (reply.isValid()) {
                    subscribeToSessionActive(bus, reply.value().path());
                    return;
                }
                qWarning("wekde::TTYSwitchMonitor: GetSessionByPID failed (%s); "
                         "trying XDG_SESSION_ID instead",
                         qUtf8Printable(reply.error().message()));
                resolveSessionByXdgSessionId(bus);
            });
}

void TTYSwitchMonitor::resolveSessionByXdgSessionId(QDBusConnection bus) {
    // GetSessionByPID resolves a PID to a session by matching a
    // session-N.scope component in that process's cgroup path. Under a
    // systemd-managed Plasma session (Fedora/Bazzite's mainline setup, this
    // project's primary distribution target) plasmashell instead runs as a
    // user service -- plasma-plasmashell.service, under user@<uid>.service's
    // own tree -- which never has that scope component, so the lookup fails
    // unconditionally there, not just occasionally. XDG_SESSION_ID is set by
    // pam_systemd at login and inherited into the systemd user manager's
    // environment, and from there into every unit it starts, so it survives
    // the indirection that breaks the cgroup-based lookup.
    const QByteArray sessionId = qgetenv("XDG_SESSION_ID");
    if (sessionId.isEmpty()) {
        qWarning("wekde::TTYSwitchMonitor: XDG_SESSION_ID not set either; "
                 "pause-on-VT-switch disabled");
        return;
    }
    QDBusMessage getSession = QDBusMessage::createMethodCall("org.freedesktop.login1",
                                                             "/org/freedesktop/login1",
                                                             "org.freedesktop.login1.Manager",
                                                             "GetSession");
    getSession << QString::fromUtf8(sessionId);
    auto* watcher = new QDBusPendingCallWatcher(bus.asyncCall(getSession), this);
    connect(watcher,
            &QDBusPendingCallWatcher::finished,
            this,
            // Same mutable-capture reasoning as resolveSessionByPid's watcher.
            [this, bus](QDBusPendingCallWatcher* w) mutable {
                w->deleteLater();
                QDBusPendingReply<QDBusObjectPath> reply = *w;
                if (! reply.isValid()) {
                    qWarning("wekde::TTYSwitchMonitor: GetSession(XDG_SESSION_ID) failed "
                             "(%s); pause-on-VT-switch disabled",
                             qUtf8Printable(reply.error().message()));
                    return;
                }
                subscribeToSessionActive(bus, reply.value().path());
            });
}

void TTYSwitchMonitor::subscribeToSessionActive(QDBusConnection bus, const QString& sessionPath) {
    bool subscribed =
        bus.connect("org.freedesktop.login1",
                    sessionPath,
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                    this,
                    SLOT(handleSessionPropertiesChanged(QString, QVariantMap, QStringList)));
    if (! subscribed) {
        qWarning("wekde::TTYSwitchMonitor: failed to subscribe to session "
                 "PropertiesChanged; pause-on-VT-switch disabled");
    }
}

void TTYSwitchMonitor::handlePrepareForSleep(bool sleep) {
    m_suspending = sleep;
    updateSleeping();
}

void TTYSwitchMonitor::handleSessionActiveChanged(bool active) {
    m_sessionActive = active;
    updateSleeping();
}

void TTYSwitchMonitor::handleSessionPropertiesChanged(
    const QString& interfaceName, const QVariantMap& changedProperties,
    const QStringList& /*invalidatedProperties*/) {
    if (interfaceName != "org.freedesktop.login1.Session") return;
    const auto it = changedProperties.constFind("Active");
    if (it == changedProperties.constEnd()) return;
    handleSessionActiveChanged(it->toBool());
}

void TTYSwitchMonitor::updateSleeping() {
    const bool sleeping = m_suspending || ! m_sessionActive;
    if (m_sleeping != sleeping) {
        m_sleeping = sleeping;
        emit ttySwitch(sleeping);
    }
}
