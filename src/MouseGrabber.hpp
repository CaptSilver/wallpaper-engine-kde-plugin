#pragma once
#include <QQuickItem>
#include <QEvent>
#include <QMouseEvent>
#include <QHoverEvent>
#include <QPointer>

namespace wekde
{

class MouseGrabber : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(bool forceCapture READ forceCapture WRITE setForceCapture NOTIFY forceCaptureChanged)
    Q_PROPERTY(QQuickItem* target READ target WRITE setTarget NOTIFY targetChanged)

public:
    MouseGrabber(QQuickItem* parent = nullptr);
    virtual ~MouseGrabber() override {};

    bool        forceCapture() const;
    QQuickItem* target() const;

    void setForceCapture(bool);
    void setTarget(QQuickItem*);

    Q_INVOKABLE void sendEvent(QObject*, QEvent*);

protected:
    void mouseUngrabEvent() override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void mouseDoubleClickEvent(QMouseEvent*) override;
    void hoverMoveEvent(QHoverEvent*) override;

signals:
    void forceCaptureChanged();
    void targetChanged();

private:
    void                 sendMouseEvent(QMouseEvent*);
    void                 sendHoverEvent(QHoverEvent*);
    bool                 m_forceCapture { false };
    QPointer<QQuickItem> m_target { nullptr };
    // Snapshot of m_target->acceptedMouseButtons() captured BEFORE the grabber
    // overwrites it with Qt::LeftButton. Restored on detach (target change or
    // null clear). NoButton matches the QQuickItem default, so a never-attached
    // grabber's cache is harmless.
    Qt::MouseButtons m_prevTargetButtons { Qt::NoButton };
};
} // namespace wekde
