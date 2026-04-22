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
    QVERIFY(true);
}

void TestMouseGrabber::mouseRelease_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonRelease);
    g.mouseReleaseEvent(&ev);
    QVERIFY(true);
}

void TestMouseGrabber::mouseDoubleClick_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkMouse(QEvent::MouseButtonDblClick);
    g.mouseDoubleClickEvent(&ev);
    QVERIFY(true);
}

void TestMouseGrabber::hoverMove_nullTarget_noCrash() {
    TestableMouseGrabber g;
    auto                 ev = mkHover();
    g.hoverMoveEvent(&ev);
    QVERIFY(true);
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

QTEST_GUILESS_MAIN(TestMouseGrabber)
#include "tst_mousegrabber.moc"
