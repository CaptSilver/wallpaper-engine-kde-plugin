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
    mon.handleActiveChanged(true);   // first interface fires
    mon.handleActiveChanged(true);   // second interface fires the same value
    QCOMPARE(spy.count(), 1);
    QCOMPARE(mon.isActive(), true);
}

QTEST_MAIN(TestScreenSaverMonitor)
#include "tst_screensavermonitor.moc"
