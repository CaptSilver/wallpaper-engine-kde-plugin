// Unit tests for wekde::ScreenSaverMonitor — the screen-lock signal bridge
// that pauses the renderer when the session locks or the screensaver kicks
// in. The D-Bus connect in the ctor depends on a session bus that isn't
// reachable from the test harness (per feedback_distrobox_dbus_launch_missing
// — neither dbus-launch nor dbus-run-session ship in the Bazzite Fedora
// toolbox container), but the slot itself is plain Qt code: it serialises
// bool changes through the `screenSaverActiveChanged(bool)` signal and
// dedupes same-state calls (cross-interface dedup absorbs the second of two
// fires when both org.freedesktop.ScreenSaver AND org.kde.screensaver hand
// us the same ActiveChanged event).

#include "ScreenSaverMonitor.hpp"
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVirtualObject>
#include <QSignalSpy>
#include <QtTest/QtTest>

using wekde::ScreenSaverMonitor;

class TestScreenSaverMonitor : public QObject {
    Q_OBJECT

private slots:
    void initialState_isInactive();
    void handleActiveChanged_trueFlipsAndEmits();
    void handleActiveChanged_falseFlipsBackAndEmits();
    void handleActiveChanged_sameStateIsIdempotent();
    void handleActiveChanged_emitsCarryNewValue();
    void activeProperty_reflectsLastDispatchedState();
    void pmfConnect_signatureCompilesWithMatchingSlot();
    void crossInterfaceDedup_secondFireAbsorbed();
    void initialQuery_alreadyActiveAtConstruction_reportsActiveWithoutSignal();
    void initialQuery_alreadyInactiveAtConstruction_reportsInactiveWithoutSignal();
    void serviceReappearance_requeriesAndAdoptsNewState();
};

void TestScreenSaverMonitor::initialState_isInactive() {
    ScreenSaverMonitor mon;
    QCOMPARE(mon.isActive(), false);
}

void TestScreenSaverMonitor::handleActiveChanged_trueFlipsAndEmits() {
    ScreenSaverMonitor mon;
    QSignalSpy         spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);
    mon.handleActiveChanged(true);
    QCOMPARE(mon.isActive(), true);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), true);
}

void TestScreenSaverMonitor::handleActiveChanged_falseFlipsBackAndEmits() {
    ScreenSaverMonitor mon;
    QSignalSpy         spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);
    mon.handleActiveChanged(true);  // active
    mon.handleActiveChanged(false); // inactive
    QCOMPARE(mon.isActive(), false);
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toBool(), false);
}

void TestScreenSaverMonitor::handleActiveChanged_sameStateIsIdempotent() {
    // The dedupe guard prevents duplicate emits when the same ActiveChanged
    // event arrives twice (e.g. one per subscribed interface) — pause-on-
    // lock would otherwise toggle the render state twice per real lock event.
    ScreenSaverMonitor mon;
    QSignalSpy         spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);
    mon.handleActiveChanged(false); // already false -> no emit
    QCOMPARE(spy.count(), 0);
    mon.handleActiveChanged(true); // false->true -> emit
    mon.handleActiveChanged(true); // true->true  -> no emit
    mon.handleActiveChanged(true); // true->true  -> no emit
    QCOMPARE(spy.count(), 1);
    QCOMPARE(mon.isActive(), true);
}

void TestScreenSaverMonitor::handleActiveChanged_emitsCarryNewValue() {
    // Each emit must carry the NEW state — a regression that mis-routed the
    // arg (e.g., passing m_active before the assignment) would still emit
    // the right count but break consumers reading the bool.
    ScreenSaverMonitor mon;
    QSignalSpy         spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);
    mon.handleActiveChanged(true);
    mon.handleActiveChanged(false);
    mon.handleActiveChanged(true);
    QCOMPARE(spy.count(), 3);
    QCOMPARE(spy.at(0).at(0).toBool(), true);
    QCOMPARE(spy.at(1).at(0).toBool(), false);
    QCOMPARE(spy.at(2).at(0).toBool(), true);
}

void TestScreenSaverMonitor::activeProperty_reflectsLastDispatchedState() {
    // Q_PROPERTY(bool active READ isActive NOTIFY screenSaverActiveChanged).
    // The signal name doubles as the NOTIFY for the property, so QML
    // bindings on `.active` re-evaluate on every state flip.
    ScreenSaverMonitor mon;
    QSignalSpy         spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);
    mon.handleActiveChanged(true);
    QCOMPARE(mon.property("active").toBool(), true);
    mon.handleActiveChanged(false);
    QCOMPARE(mon.property("active").toBool(), false);
    QCOMPARE(spy.count(), 2);
}

void TestScreenSaverMonitor::pmfConnect_signatureCompilesWithMatchingSlot() {
    // Compile-time pin on handleActiveChanged's signature. The production
    // QDBusConnection::connect in ScreenSaverMonitor.cpp uses the legacy
    // SLOT(handleActiveChanged(bool)) string macro — Qt6's QDBusConnection
    // does not (as of 6.10.3) expose a pointer-to-member-function overload,
    // so the connect-site itself can't be made compile-checked. This test
    // case takes the next-best step: it forms a member pointer with the
    // exact `void (bool)` shape the SLOT macro string baked in. If a future
    // refactor renames the slot, changes its parameter type/arity, or drops
    // it entirely, this assignment fails to COMPILE in the test build —
    // surfacing the drift at gate time rather than at runtime via a silently-
    // returning-false connect() and a journal qWarning.
    using SlotPtr = void (ScreenSaverMonitor::*)(bool);
    SlotPtr p     = &ScreenSaverMonitor::handleActiveChanged;
    // QVERIFY keeps the compiler from optimising the pointer assignment
    // away. The *compile-time* check is the contract; this runtime
    // assertion is just liveness so the case shows up in QtTest output.
    QVERIFY(p != nullptr);
}

void TestScreenSaverMonitor::crossInterfaceDedup_secondFireAbsorbed() {
    // Both org.freedesktop.ScreenSaver and org.kde.screensaver route to the
    // SAME slot. Firing twice (one per interface) must look identical to a
    // single ActiveChanged(true) at the QML layer — the state-edge guard
    // absorbs the second emit.
    ScreenSaverMonitor mon;
    QSignalSpy         spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);
    mon.handleActiveChanged(true); // first interface fires
    mon.handleActiveChanged(true); // second interface fires the same value
    QCOMPARE(spy.count(), 1);
    QCOMPARE(mon.isActive(), true);
}

// ===========================================================================
// Live-DBus driver — FakeScreenSaverService
// ===========================================================================
//
// Registers a real org.freedesktop.ScreenSaver service on the session bus
// and answers GetActive() with a canned value, driving the ctor's initial
// query (and the service-watcher requery) that the no-injection tests above
// can't reach. Mirrors FakeMprisService/FakeMprisRegistration in
// tst_mpriscolors.cpp. QSKIPs rather than fails when no session bus is
// reachable (the distrobox test harness, per
// feedback_distrobox_dbus_launch_missing) or a real kded_screenlocker
// already owns the name.
class FakeScreenSaverService : public QDBusVirtualObject {
public:
    explicit FakeScreenSaverService(bool active): m_active(active) {}

    QString introspect(const QString& /*path*/) const override {
        return QStringLiteral("<interface name=\"org.freedesktop.ScreenSaver\">"
                              "  <method name=\"GetActive\">"
                              "    <arg direction=\"out\" name=\"active\" type=\"b\"/>"
                              "  </method>"
                              "</interface>");
    }

    bool handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override {
        if (message.interface() != "org.freedesktop.ScreenSaver") return false;
        if (message.member() != "GetActive") return false;
        return connection.send(message.createReply(m_active));
    }

private:
    bool m_active;
};

// RAII helper: registers org.freedesktop.ScreenSaver + /ScreenSaver and
// unregisters on destruction (or on an explicit unregisterNow(), needed to
// free the name up for a second registration within the same test).
class FakeScreenSaverRegistration {
public:
    explicit FakeScreenSaverRegistration(FakeScreenSaverService* svc)
        : m_bus(QDBusConnection::sessionBus()) {
        if (! m_bus.isConnected()) return;
        m_objectRegistered  = m_bus.registerVirtualObject(QStringLiteral("/ScreenSaver"), svc);
        m_serviceRegistered = m_bus.registerService(QStringLiteral("org.freedesktop.ScreenSaver"));
    }
    ~FakeScreenSaverRegistration() { unregisterNow(); }

    void unregisterNow() {
        if (m_serviceRegistered) {
            m_bus.unregisterService(QStringLiteral("org.freedesktop.ScreenSaver"));
            m_serviceRegistered = false;
        }
        if (m_objectRegistered) {
            m_bus.unregisterObject(QStringLiteral("/ScreenSaver"));
            m_objectRegistered = false;
        }
    }

    bool ok() const { return m_serviceRegistered && m_objectRegistered; }

private:
    QDBusConnection m_bus;
    bool            m_objectRegistered { false };
    bool            m_serviceRegistered { false };
};

void TestScreenSaverMonitor::initialQuery_alreadyActiveAtConstruction_reportsActiveWithoutSignal() {
    FakeScreenSaverService      svc(/*active=*/true);
    FakeScreenSaverRegistration reg(&svc);
    if (! reg.ok())
        QSKIP("session bus or org.freedesktop.ScreenSaver registration unavailable in this env");

    // No ActiveChanged signal is ever sent — only the ctor's initial
    // GetActive() query can move m_active here.
    ScreenSaverMonitor mon(QDBusConnection::sessionBus(), /*parent=*/nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(mon.isActive(), true, 2000);
}

void TestScreenSaverMonitor::
    initialQuery_alreadyInactiveAtConstruction_reportsInactiveWithoutSignal() {
    FakeScreenSaverService      svc(/*active=*/false);
    FakeScreenSaverRegistration reg(&svc);
    if (! reg.ok())
        QSKIP("session bus or org.freedesktop.ScreenSaver registration unavailable in this env");

    ScreenSaverMonitor mon(QDBusConnection::sessionBus(), /*parent=*/nullptr);
    // Give the async query a moment to land, then confirm it settled on (and
    // stayed) inactive rather than drifting true from some other path.
    QTest::qWait(200);
    QCOMPARE(mon.isActive(), false);
}

void TestScreenSaverMonitor::serviceReappearance_requeriesAndAdoptsNewState() {
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (! bus.isConnected()) QSKIP("no session bus — distrobox without dbus-launch");

    FakeScreenSaverService      svc(/*active=*/false);
    FakeScreenSaverRegistration reg(&svc);
    if (! reg.ok()) QSKIP("org.freedesktop.ScreenSaver registration unavailable in this env");

    ScreenSaverMonitor mon(bus, /*parent=*/nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(mon.isActive(), false, 2000);

    QSignalSpy spy(&mon, &ScreenSaverMonitor::screenSaverActiveChanged);

    // Simulate kded_screenlocker restarting mid-session: drop off the bus
    // and come back with a DIFFERENT answer. No ActiveChanged signal is
    // sent — only the reappearance requery can move m_active here.
    reg.unregisterNow();
    FakeScreenSaverService      svc2(/*active=*/true);
    FakeScreenSaverRegistration reg2(&svc2);
    if (! reg2.ok()) QSKIP("could not re-register org.freedesktop.ScreenSaver for this test");

    QTRY_COMPARE_WITH_TIMEOUT(mon.isActive(), true, 2000);
    QVERIFY(spy.count() >= 1);
}

QTEST_MAIN(TestScreenSaverMonitor)
#include "tst_screensavermonitor.moc"
