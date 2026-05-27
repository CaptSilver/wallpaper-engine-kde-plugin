// Unit tests for wekde::TTYSwitchMonitor — the suspend/wake signal bridge that
// drives the renderer's pause-on-suspend behaviour. The D-Bus connect in the
// ctor depends on a system bus that isn't reachable from the test harness, but
// the slot itself is plain Qt code: it serialises bool changes through the
// `ttySwitch(bool)` signal and dedupes same-state calls.

#include "TTYSwitchMonitor.hpp"
#include <QSignalSpy>
#include <QtTest/QtTest>

using wekde::TTYSwitchMonitor;

class TestTTYSwitchMonitor : public QObject {
    Q_OBJECT

private slots:
    void initialState_isAwake();
    void handlePrepareForSleep_trueFlipsAndEmits();
    void handlePrepareForSleep_falseFlipsBackAndEmits();
    void handlePrepareForSleep_sameStateIsIdempotent();
    void handlePrepareForSleep_emitsCarryNewValue();
    void sleepingProperty_reflectsLastDispatchedState();
    void pmfConnect_signatureCompilesWithMatchingSlot();
};

void TestTTYSwitchMonitor::initialState_isAwake() {
    TTYSwitchMonitor mon;
    QCOMPARE(mon.isSleeping(), false);
}

void TestTTYSwitchMonitor::handlePrepareForSleep_trueFlipsAndEmits() {
    TTYSwitchMonitor mon;
    QSignalSpy       spy(&mon, &TTYSwitchMonitor::ttySwitch);
    mon.handlePrepareForSleep(true);
    QCOMPARE(mon.isSleeping(), true);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), true);
}

void TestTTYSwitchMonitor::handlePrepareForSleep_falseFlipsBackAndEmits() {
    TTYSwitchMonitor mon;
    QSignalSpy       spy(&mon, &TTYSwitchMonitor::ttySwitch);
    mon.handlePrepareForSleep(true);  // sleep
    mon.handlePrepareForSleep(false); // wake
    QCOMPARE(mon.isSleeping(), false);
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toBool(), false);
}

void TestTTYSwitchMonitor::handlePrepareForSleep_sameStateIsIdempotent() {
    // The dedupe guard at TTYSwitchMonitor.cpp:31 prevents duplicate emits
    // when systemd repeats PrepareForSleep — pause-on-suspend would
    // otherwise toggle the render state twice per real event.
    TTYSwitchMonitor mon;
    QSignalSpy       spy(&mon, &TTYSwitchMonitor::ttySwitch);
    mon.handlePrepareForSleep(false); // already false → no emit
    QCOMPARE(spy.count(), 0);
    mon.handlePrepareForSleep(true); // false→true → emit
    mon.handlePrepareForSleep(true); // true→true  → no emit
    mon.handlePrepareForSleep(true); // true→true  → no emit
    QCOMPARE(spy.count(), 1);
    QCOMPARE(mon.isSleeping(), true);
}

void TestTTYSwitchMonitor::handlePrepareForSleep_emitsCarryNewValue() {
    // Each emit must carry the NEW state — a regression that mis-routed the
    // arg (e.g., passing m_sleeping before the assignment) would still emit
    // the right count but break consumers reading the bool.
    TTYSwitchMonitor mon;
    QSignalSpy       spy(&mon, &TTYSwitchMonitor::ttySwitch);
    mon.handlePrepareForSleep(true);
    mon.handlePrepareForSleep(false);
    mon.handlePrepareForSleep(true);
    QCOMPARE(spy.count(), 3);
    QCOMPARE(spy.at(0).at(0).toBool(), true);
    QCOMPARE(spy.at(1).at(0).toBool(), false);
    QCOMPARE(spy.at(2).at(0).toBool(), true);
}

void TestTTYSwitchMonitor::sleepingProperty_reflectsLastDispatchedState() {
    // Q_PROPERTY(bool sleeping READ isSleeping NOTIFY ttySwitch). The
    // signal name doubles as the NOTIFY for the property, so QML bindings
    // re-evaluate on every state flip.
    TTYSwitchMonitor mon;
    QSignalSpy       spy(&mon, &TTYSwitchMonitor::ttySwitch);
    mon.handlePrepareForSleep(true);
    QCOMPARE(mon.property("sleeping").toBool(), true);
    mon.handlePrepareForSleep(false);
    QCOMPARE(mon.property("sleeping").toBool(), false);
    QCOMPARE(spy.count(), 2);
}

void TestTTYSwitchMonitor::pmfConnect_signatureCompilesWithMatchingSlot() {
    // Compile-time pin on handlePrepareForSleep's signature. The production
    // QDBusConnection::connect in TTYSwitchMonitor.cpp uses the legacy
    // SLOT(handlePrepareForSleep(bool)) string macro — Qt6's QDBusConnection
    // does not (as of 6.10.3) expose a pointer-to-member-function overload,
    // so the connect-site itself can't be made compile-checked. This test
    // case takes the next-best step: it forms a member pointer with the
    // exact `void (bool)` shape the SLOT macro string baked in. If a future
    // refactor renames the slot, changes its parameter type/arity, or drops
    // it entirely, this assignment fails to COMPILE in the test build —
    // surfacing the drift at gate time rather than at runtime via a silently-
    // returning-false connect() and a journal qWarning.
    using SlotPtr = void (TTYSwitchMonitor::*)(bool);
    SlotPtr p     = &TTYSwitchMonitor::handlePrepareForSleep;
    // QVERIFY keeps the compiler from optimising the pointer assignment
    // away. The *compile-time* check is the contract; this runtime
    // assertion is just liveness so the case shows up in QtTest output.
    QVERIFY(p != nullptr);
}

QTEST_MAIN(TestTTYSwitchMonitor)
#include "tst_ttyswitchmonitor.moc"
