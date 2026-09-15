#include "MouseGrabber.hpp"
#include <iostream>
#include <QLoggingCategory>
#include <QCoreApplication>
#include <QHoverEvent>
#include <QMouseEvent>
#include <QtGlobal>

using namespace wekde;

MouseGrabber::MouseGrabber(QQuickItem* parent): QQuickItem(parent) {
    setAcceptedMouseButtons(Qt::LeftButton);
    setAcceptHoverEvents(true);
}

bool MouseGrabber::forceCapture() const { return m_forceCapture; }

QQuickItem* MouseGrabber::target() const { return m_target; }

void MouseGrabber::setForceCapture(bool value) {
    if (value == m_forceCapture) return;
    m_forceCapture = value;
    if (value) {
        grabMouse();
    } else {
        ungrabMouse();
    }
    Q_EMIT forceCaptureChanged();
}

void MouseGrabber::setTarget(QQuickItem* item) {
    if (item == m_target) return;
    // Restore the OLD target's accepted-button mask to whatever the QML
    // author set it to before the grabber attached. QPointer auto-nulls if
    // the underlying QQuickItem was destroyed, so the if-check is also a
    // dead-pointer guard.
    if (m_target) m_target->setAcceptedMouseButtons(m_prevTargetButtons);
    m_target = item;
    if (m_target) {
        // Snapshot BEFORE overwrite so a chain setTarget(A)->setTarget(B)->
        // setTarget(A) returns A and B to their original masks.
        m_prevTargetButtons = m_target->acceptedMouseButtons();
        m_target->setAcceptedMouseButtons(Qt::LeftButton);
    } else {
        m_prevTargetButtons = Qt::NoButton;
    }
    Q_EMIT targetChanged();
}

void MouseGrabber::mouseUngrabEvent() {
    if (m_forceCapture) grabMouse();
}

void MouseGrabber::sendEvent(QObject* target, QEvent* event) {
    QCoreApplication::sendEvent(target, event);
}

void MouseGrabber::sendMouseEvent(QMouseEvent* event) {
    if (m_target) {
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
        QMouseEvent temp(event->type(),
                         mapToItem(m_target, event->position()),
                         event->globalPosition(),
                         event->button(),
                         event->buttons(),
                         event->modifiers());
#else
        QMouseEvent temp(event->type(),
                         mapToItem(m_target, event->localPos()),
                         event->screenPos(),
                         event->button(),
                         event->buttons(),
                         event->modifiers());
#endif
        QCoreApplication::sendEvent(m_target, &temp);
    }
}

void MouseGrabber::sendHoverEvent(QHoverEvent* event) {
    if (m_target) {
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
        auto        newPos = mapToItem(m_target, event->position());
        QHoverEvent temp(event->type(),
                         newPos,
                         event->globalPosition(),
                         mapToItem(m_target, event->oldPosF()),
                         event->modifiers());
#else
        QHoverEvent temp(event->type(),
                         mapToItem(m_target, event->posF()),
                         mapToItem(m_target, event->oldPosF()),
                         event->modifiers());
#endif
        QCoreApplication::sendEvent(m_target, &temp);
    }
}

void MouseGrabber::mousePressEvent(QMouseEvent* event) {
    sendMouseEvent(event);
    // need accept press to receive release
    // this break long press on desktop
    event->accept();
}

void MouseGrabber::mouseMoveEvent(QMouseEvent* event) {
    sendMouseEvent(event);
    event->ignore();
}

void MouseGrabber::mouseReleaseEvent(QMouseEvent* event) {
    sendMouseEvent(event);
    event->ignore();
}

void MouseGrabber::mouseDoubleClickEvent(QMouseEvent* event) {
    sendMouseEvent(event);
    event->ignore();
}

void MouseGrabber::hoverMoveEvent(QHoverEvent* event) {
    // Sample log once per ~120 hover events so we can tell from journalctl
    // whether hover is actually reaching the wallpaper.  Demoted from
    // qInfo to qDebug so the steady drip doesn't flood plasmashell logs
    // in normal operation; users debugging mouse-hook issues can enable
    // QT_LOGGING_RULES="*.debug=true" to re-enable.
    static int s_hover_log = 0;
    if (++s_hover_log % 120 == 1) {
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
        auto pos = event->position();
#else
        auto pos = event->posF();
#endif
        qDebug("[WEK] MouseGrabber::hoverMoveEvent pos=(%.1f,%.1f) target=%p",
               pos.x(),
               pos.y(),
               (void*)m_target);
    }
    sendHoverEvent(event);
    event->ignore();
}
