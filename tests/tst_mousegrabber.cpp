#include <QtTest>
#include <QCoreApplication>
#include <QEvent>
#include <QHoverEvent>
#include <QMouseEvent>
#include <QPointF>
#include <QQuickItem>
#include <QSignalSpy>
#include "MouseGrabber.hpp"

// Expose the protected event handlers for direct unit testing.  Without a
// QQuickWindow to deliver real events, the handlers are invoked as-if from
// the scene via this subclass.
class TestableMouseGrabber : public wekde::MouseGrabber {
public:
    using wekde::MouseGrabber::hoverMoveEvent;
    using wekde::MouseGrabber::mouseDoubleClickEvent;
    using wekde::MouseGrabber::MouseGrabber;
    using wekde::MouseGrabber::mouseMoveEvent;
    using wekde::MouseGrabber::mousePressEvent;
    using wekde::MouseGrabber::mouseReleaseEvent;
    using wekde::MouseGrabber::mouseUngrabEvent;
};

// Captures events sent to the item it's installed on, so tests can verify
// that MouseGrabber forwarded a synthesized event to its target.  Records
// type + position for each mouse/hover event and lets them continue.
class EventCapturingFilter : public QObject {
public:
    QList<QEvent::Type>    types;
    QList<QPointF>         positions;
    QList<Qt::MouseButton> buttons;

    bool eventFilter(QObject* /*watched*/, QEvent* ev) override {
        types.append(ev->type());
        switch (ev->type()) {
        case QEvent::MouseButtonPress:
        case QEvent::MouseMove:
        case QEvent::MouseButtonRelease:
        case QEvent::MouseButtonDblClick: {
            auto* me = static_cast<QMouseEvent*>(ev);
            positions.append(me->position());
            buttons.append(me->button());
            break;
        }
        case QEvent::HoverMove: {
            auto* he = static_cast<QHoverEvent*>(ev);
            positions.append(he->position());
            buttons.append(Qt::NoButton);
            break;
        }
        default: break;
        }
        // Consume mouse/hover events so target->event() doesn't try to run
        // scene-dependent code on a parentless QQuickItem.  Non-input events
        // pass through unchanged.
        switch (ev->type()) {
        case QEvent::MouseButtonPress:
        case QEvent::MouseMove:
        case QEvent::MouseButtonRelease:
        case QEvent::MouseButtonDblClick:
        case QEvent::HoverMove: return true;
        default: return false;
        }
    }
};

class TestMouseGrabber : public QObject {
    Q_OBJECT
private slots:
    // Construction + properties
    void defaultState();
    void setTarget_emitsSignalOnChange();
    void setTarget_sameValueNoSignal();
    void setTarget_nullClears();
    void setTarget_updatesAcceptedMouseButtons();
    void setTarget_restoresPrevTargetMask_onChange();
    void setTarget_restoresPrevTargetMask_onClear();
    void setTarget_preservesCustomPriorMask();
    void setTarget_destroyedPrevTarget_noCrash();
    void setTarget_chainedAttachDetach_restoresEachInTurn();
    void setForceCapture_emitsSignalOnChange();
    void setForceCapture_sameValueNoSignal();
    void setForceCapture_togglesBackToFalse();

    // sendEvent Q_INVOKABLE
    void sendEvent_forwardsViaQCoreApplication();

    // Mouse event forwarding to target
    void mousePress_forwardsToTarget();
    void mouseMove_forwardsToTarget();
    void mouseRelease_forwardsToTarget();
    void mouseDoubleClick_forwardsToTarget();
    void hoverMove_forwardsToTarget();

    // Accept / ignore semantics
    void mousePress_acceptsEvent();
    void mouseMove_ignoresEvent();
    void mouseRelease_ignoresEvent();
    void mouseDoubleClick_ignoresEvent();
    void hoverMove_ignoresEvent();

    // Null target must not crash
    void mousePress_nullTarget_noCrash();
    void mouseMove_nullTarget_noCrash();
    void mouseRelease_nullTarget_noCrash();
    void mouseDoubleClick_nullTarget_noCrash();
    void hoverMove_nullTarget_noCrash();

    // mouseUngrabEvent behavior
    void mouseUngrab_withoutForce_noRegrab();
    void mouseUngrab_withForce_attemptsRegrab();

    // Mid-event target swap — target nulled between press and release.
    // Pins the `if (m_target)` guard in sendMouseEvent.
    void setTarget_nullBetweenPressAndRelease_noCrash();
};

// ---------------------------------------------------------------------------
// Construction + properties
// ---------------------------------------------------------------------------

void TestMouseGrabber::defaultState() {
    wekde::MouseGrabber g;
    QCOMPARE(g.forceCapture(), false);
    QCOMPARE(g.target(), nullptr);
    // Ctor configures accepted mouse buttons and hover events
    QCOMPARE(g.acceptedMouseButtons(), Qt::LeftButton);
    QVERIFY(g.acceptHoverEvents());
}

void TestMouseGrabber::setTarget_emitsSignalOnChange() {
    wekde::MouseGrabber g;
    QQuickItem          item;
    QSignalSpy          spy(&g, &wekde::MouseGrabber::targetChanged);
    g.setTarget(&item);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(g.target(), &item);
}

void TestMouseGrabber::setTarget_sameValueNoSignal() {
    wekde::MouseGrabber g;
    QQuickItem          item;
    g.setTarget(&item);
    QSignalSpy spy(&g, &wekde::MouseGrabber::targetChanged);
    g.setTarget(&item); // same
    QCOMPARE(spy.count(), 0);
}

void TestMouseGrabber::setTarget_nullClears() {
    wekde::MouseGrabber g;
    QQuickItem          item;
    g.setTarget(&item);
    QSignalSpy spy(&g, &wekde::MouseGrabber::targetChanged);
    g.setTarget(nullptr);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(g.target(), nullptr);
}

void TestMouseGrabber::setTarget_updatesAcceptedMouseButtons() {
    wekde::MouseGrabber g;
    QQuickItem          item;
    QCOMPARE(item.acceptedMouseButtons(), Qt::NoButton);
    g.setTarget(&item);
    // setTarget configures the target item for LeftButton reception so
    // forwarded press events aren't silently discarded by Quick.
    QCOMPARE(item.acceptedMouseButtons(), Qt::LeftButton);
}

// After re-targeting, the PREVIOUS target's mask must be restored to
// whatever it was before the grabber attached (default NoButton for QML
// items the author didn't customise). The leak this guards against: a
// backend swap (Scene -> Mpv -> Web) progressively flips every former
// target to LeftButton, which mis-routes clicks for sibling overlapping
// MouseAreas.
void TestMouseGrabber::setTarget_restoresPrevTargetMask_onChange() {
    wekde::MouseGrabber g;
    QQuickItem          a;
    QQuickItem          b;
    QCOMPARE(a.acceptedMouseButtons(), Qt::NoButton);
    QCOMPARE(b.acceptedMouseButtons(), Qt::NoButton);
    g.setTarget(&a);
    QCOMPARE(a.acceptedMouseButtons(), Qt::LeftButton);
    g.setTarget(&b);
    QCOMPARE(a.acceptedMouseButtons(), Qt::NoButton);   // restored
    QCOMPARE(b.acceptedMouseButtons(), Qt::LeftButton); // newly attached
}

// Clearing the target (setTarget(nullptr)) must also restore the prev mask.
void TestMouseGrabber::setTarget_restoresPrevTargetMask_onClear() {
    wekde::MouseGrabber g;
    QQuickItem          a;
    g.setTarget(&a);
    QCOMPARE(a.acceptedMouseButtons(), Qt::LeftButton);
    g.setTarget(nullptr);
    QCOMPARE(a.acceptedMouseButtons(), Qt::NoButton);
}

// Author-customised mask (Right+Middle) survives an attach/detach cycle.
// The grabber owns the mask while attached but must not corrupt a value
// the QML author deliberately set.
void TestMouseGrabber::setTarget_preservesCustomPriorMask() {
    wekde::MouseGrabber g;
    QQuickItem          a;
    a.setAcceptedMouseButtons(Qt::RightButton | Qt::MiddleButton);
    g.setTarget(&a);
    QCOMPARE(a.acceptedMouseButtons(), Qt::LeftButton); // grabber owns while attached
    g.setTarget(nullptr);
    QCOMPARE(a.acceptedMouseButtons(), Qt::RightButton | Qt::MiddleButton);
}

// QPointer auto-null: if the prev target is destroyed before the next
// setTarget call, the restore branch must short-circuit without
// dereferencing a stale pointer. (Heap-allocate to control destruction.)
void TestMouseGrabber::setTarget_destroyedPrevTarget_noCrash() {
    wekde::MouseGrabber g;
    QQuickItem*         a = new QQuickItem;
    QQuickItem          b;
    g.setTarget(a);
    delete a;        // m_target auto-nulls (QPointer)
    g.setTarget(&b); // must NOT crash; restore branch skipped
    QCOMPARE(b.acceptedMouseButtons(), Qt::LeftButton);
}

// Full chained sequence: setTarget(A) -> setTarget(B) -> setTarget(nullptr).
// Pins that each step BOTH restores the prior target's mask AND captures the
// new target's mask before overwriting, so the cache never carries A's
// pre-attach mask into B's restore (the regression class this fix prevents).
void TestMouseGrabber::setTarget_chainedAttachDetach_restoresEachInTurn() {
    wekde::MouseGrabber g;
    QQuickItem          a;
    QQuickItem          b;
    a.setAcceptedMouseButtons(Qt::RightButton);
    b.setAcceptedMouseButtons(Qt::MiddleButton);

    g.setTarget(&a);
    QCOMPARE(a.acceptedMouseButtons(), Qt::LeftButton);
    QCOMPARE(b.acceptedMouseButtons(), Qt::MiddleButton); // untouched

    g.setTarget(&b);
    QCOMPARE(a.acceptedMouseButtons(), Qt::RightButton); // A restored to pre-attach
    QCOMPARE(b.acceptedMouseButtons(), Qt::LeftButton);  // B now owned by grabber

    g.setTarget(nullptr);
    QCOMPARE(a.acceptedMouseButtons(), Qt::RightButton);  // A still its pre-attach
    QCOMPARE(b.acceptedMouseButtons(), Qt::MiddleButton); // B restored to pre-attach
}

void TestMouseGrabber::setForceCapture_emitsSignalOnChange() {
    wekde::MouseGrabber g;
    QSignalSpy          spy(&g, &wekde::MouseGrabber::forceCaptureChanged);
    // grabMouse() inside setForceCapture(true) is a silent no-op without a
    // QQuickWindow in Qt 6; the state change still fires the signal.
    g.setForceCapture(true);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(g.forceCapture(), true);
}

void TestMouseGrabber::setForceCapture_sameValueNoSignal() {
    wekde::MouseGrabber g;
    QSignalSpy          spy(&g, &wekde::MouseGrabber::forceCaptureChanged);
    g.setForceCapture(false); // same as default
    QCOMPARE(spy.count(), 0);
}

void TestMouseGrabber::setForceCapture_togglesBackToFalse() {
    wekde::MouseGrabber g;
    g.setForceCapture(true);
    QSignalSpy spy(&g, &wekde::MouseGrabber::forceCaptureChanged);
    g.setForceCapture(false); // exercises the ungrabMouse() branch
    QCOMPARE(spy.count(), 1);
    QCOMPARE(g.forceCapture(), false);
}

// ---------------------------------------------------------------------------
// sendEvent — Q_INVOKABLE wrapper around QCoreApplication::sendEvent
// ---------------------------------------------------------------------------

void TestMouseGrabber::sendEvent_forwardsViaQCoreApplication() {
    wekde::MouseGrabber  g;
    QQuickItem           target;
    EventCapturingFilter filter;
    target.installEventFilter(&filter);

    QMouseEvent ev(QEvent::MouseButtonPress,
                   QPointF(1, 2),
                   QPointF(1, 2),
                   Qt::LeftButton,
                   Qt::LeftButton,
                   Qt::NoModifier);
    g.sendEvent(&target, &ev);
    QCOMPARE(filter.types.size(), 1);
    QCOMPARE(filter.types.at(0), QEvent::MouseButtonPress);
}

// ---------------------------------------------------------------------------
// Mouse event forwarding
// ---------------------------------------------------------------------------

static QMouseEvent mkMouse(QEvent::Type type, QPointF pos = { 0, 0 },
                           Qt::MouseButton btn = Qt::LeftButton) {
    return QMouseEvent(type, pos, pos, btn, btn, Qt::NoModifier);
}
static QHoverEvent mkHover(QPointF pos = { 0, 0 }, QPointF oldPos = { 0, 0 }) {
    return QHoverEvent(QEvent::HoverMove, pos, pos, oldPos, Qt::NoModifier);
}

void TestMouseGrabber::mousePress_forwardsToTarget() {
    TestableMouseGrabber g;
    QQuickItem           target;
    EventCapturingFilter filter;
    g.setTarget(&target);
    target.installEventFilter(&filter);

    auto ev = mkMouse(QEvent::MouseButtonPress, QPointF(7, 11));
    g.mousePressEvent(&ev);
    QCOMPARE(filter.types.size(), 1);
    QCOMPARE(filter.types.at(0), QEvent::MouseButtonPress);
    QCOMPARE(filter.buttons.at(0), Qt::LeftButton);
}

void TestMouseGrabber::mouseMove_forwardsToTarget() {
    TestableMouseGrabber g;
    QQuickItem           target;
    EventCapturingFilter filter;
    g.setTarget(&target);
    target.installEventFilter(&filter);

    auto ev = mkMouse(QEvent::MouseMove, QPointF(50, 60));
    g.mouseMoveEvent(&ev);
    QCOMPARE(filter.types.size(), 1);
    QCOMPARE(filter.types.at(0), QEvent::MouseMove);
}

void TestMouseGrabber::mouseRelease_forwardsToTarget() {
    TestableMouseGrabber g;
    QQuickItem           target;
    EventCapturingFilter filter;
    g.setTarget(&target);
    target.installEventFilter(&filter);

    auto ev = mkMouse(QEvent::MouseButtonRelease);
    g.mouseReleaseEvent(&ev);
    QCOMPARE(filter.types.size(), 1);
    QCOMPARE(filter.types.at(0), QEvent::MouseButtonRelease);
}

void TestMouseGrabber::mouseDoubleClick_forwardsToTarget() {
    TestableMouseGrabber g;
    QQuickItem           target;
    EventCapturingFilter filter;
    g.setTarget(&target);
    target.installEventFilter(&filter);

    auto ev = mkMouse(QEvent::MouseButtonDblClick);
    g.mouseDoubleClickEvent(&ev);
    QCOMPARE(filter.types.size(), 1);
    QCOMPARE(filter.types.at(0), QEvent::MouseButtonDblClick);
}

void TestMouseGrabber::hoverMove_forwardsToTarget() {
    TestableMouseGrabber g;
    QQuickItem           target;
    EventCapturingFilter filter;
    g.setTarget(&target);
    target.installEventFilter(&filter);

    auto ev = mkHover(QPointF(3, 4));
    g.hoverMoveEvent(&ev);
    QCOMPARE(filter.types.size(), 1);
    QCOMPARE(filter.types.at(0), QEvent::HoverMove);
}

// ---------------------------------------------------------------------------
// Accept / ignore semantics — press is acknowledged so release follows,
// every other event is ignored so upstream handlers see it too.
// ---------------------------------------------------------------------------

void TestMouseGrabber::mousePress_acceptsEvent() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonPress);
    ev.ignore();
    g.mousePressEvent(&ev);
    QVERIFY(ev.isAccepted());
}

void TestMouseGrabber::mouseMove_ignoresEvent() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseMove);
    ev.accept();
    g.mouseMoveEvent(&ev);
    QVERIFY(! ev.isAccepted());
}

void TestMouseGrabber::mouseRelease_ignoresEvent() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonRelease);
    ev.accept();
    g.mouseReleaseEvent(&ev);
    QVERIFY(! ev.isAccepted());
}

void TestMouseGrabber::mouseDoubleClick_ignoresEvent() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonDblClick);
    ev.accept();
    g.mouseDoubleClickEvent(&ev);
    QVERIFY(! ev.isAccepted());
}

void TestMouseGrabber::hoverMove_ignoresEvent() {
    TestableMouseGrabber g;
    auto                 ev = mkHover();
    ev.accept();
    g.hoverMoveEvent(&ev);
    QVERIFY(! ev.isAccepted());
}

// ---------------------------------------------------------------------------
// Null target — sendMouseEvent/sendHoverEvent early-out, event handlers
// still accept/ignore correctly.
// ---------------------------------------------------------------------------

void TestMouseGrabber::mousePress_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonPress);
    g.mousePressEvent(&ev);
    QVERIFY(ev.isAccepted()); // press still accepts even with null target
}

void TestMouseGrabber::mouseMove_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseMove);
    g.mouseMoveEvent(&ev);
    // Move ignores by contract (MouseGrabber.cpp:95) — bubble to parent for hover.
    QVERIFY(! ev.isAccepted());
}

void TestMouseGrabber::mouseRelease_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonRelease);
    g.mouseReleaseEvent(&ev);
    // Release ignores by contract (MouseGrabber.cpp:100).
    QVERIFY(! ev.isAccepted());
}

void TestMouseGrabber::mouseDoubleClick_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonDblClick);
    g.mouseDoubleClickEvent(&ev);
    // Double-click ignores by contract (MouseGrabber.cpp:105).
    QVERIFY(! ev.isAccepted());
}

void TestMouseGrabber::hoverMove_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkHover();
    g.hoverMoveEvent(&ev);
    // Hover ignores by contract (MouseGrabber.cpp:127).
    QVERIFY(! ev.isAccepted());
}

// ---------------------------------------------------------------------------
// mouseUngrabEvent — only re-grabs when forceCapture is set.
// ---------------------------------------------------------------------------

void TestMouseGrabber::mouseUngrab_withoutForce_noRegrab() {
    TestableMouseGrabber g;
    // forceCapture defaults to false → mouseUngrabEvent is a no-op.
    g.mouseUngrabEvent();
    QCOMPARE(g.forceCapture(), false);
}

void TestMouseGrabber::mouseUngrab_withForce_attemptsRegrab() {
    TestableMouseGrabber g;
    g.setForceCapture(true);
    // Internal grabMouse() is a silent no-op without a window; we're
    // just exercising the forceCapture==true branch of mouseUngrabEvent.
    g.mouseUngrabEvent();
    QCOMPARE(g.forceCapture(), true);
}

void TestMouseGrabber::setTarget_nullBetweenPressAndRelease_noCrash() {
    // The QML caller may legitimately reassign target between press and
    // release (e.g. a focus-out racing with a click). Guard at
    // sendMouseEvent ensures we don't deliver to a stale pointer. Use
    // EventCapturingFilter to absorb the press cleanly without invoking
    // the QQuickItem dispatch path (which assumes a QQuickWindow).
    QQuickItem           target;
    EventCapturingFilter filter;
    TestableMouseGrabber g;
    g.setTarget(&target);
    target.installEventFilter(&filter);

    auto press = mkMouse(QEvent::MouseButtonPress);
    g.mousePressEvent(&press);
    QVERIFY(press.isAccepted());
    QCOMPARE(filter.types.size(), 1);

    // Null the target mid-stream — sendMouseEvent must early-out.
    g.setTarget(nullptr);

    auto release = mkMouse(QEvent::MouseButtonRelease);
    g.mouseReleaseEvent(&release);
    // Filter saw press only — release never dispatched (no target).
    QCOMPARE(filter.types.size(), 1);
    // Second send while target is null — still safe.
    auto move = mkMouse(QEvent::MouseMove);
    g.mouseMoveEvent(&move);
    QCOMPARE(filter.types.size(), 1);
}

QTEST_GUILESS_MAIN(TestMouseGrabber)
#include "tst_mousegrabber.moc"
