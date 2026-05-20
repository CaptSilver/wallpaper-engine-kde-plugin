#pragma once
#include <QColor>
#include <QQuickItem>
#include <QRectF>

#include "FakeConfiguration.gen.h"

// Settable per-screen geometry; FakeWallpaperItem's visual parent so that
// main.qml's `wallpaper.parent.screenGeometry` resolves to this.
class FakeContainment : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QRectF screenGeometry READ screenGeometry WRITE setScreenGeometry NOTIFY
                   screenGeometryChanged)
public:
    explicit FakeContainment(QQuickItem* parent = nullptr): QQuickItem(parent) {}
    QRectF screenGeometry() const { return m_geo; }
    void   setScreenGeometry(const QRectF& g) {
        if (g != m_geo) {
            m_geo = g;
            Q_EMIT screenGeometryChanged();
        }
    }
signals:
    void screenGeometryChanged();

private:
    QRectF m_geo { 0, 0, 1920, 1080 };
};

// The fake Plasma `wallpaper` context object. A QQuickItem so QML `wallpaper.parent`
// resolves to its visual parent (a FakeContainment). `configuration` is the
// code-generated QObject with real uppercase Q_PROPERTYs + per-key NOTIFY signals.
class FakeWallpaperItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QObject* configuration READ configuration CONSTANT)
    Q_PROPERTY(QColor accentColor READ accentColor NOTIFY accentColorChanged)
public:
    explicit FakeWallpaperItem(QQuickItem* parent = nullptr)
        : QQuickItem(parent), m_config(new FakeConfiguration(this)) {}
    QObject*           configuration() const { return m_config; }
    QColor             accentColor() const { return QColor(Qt::transparent); }
    FakeConfiguration* config() const { return m_config; }
signals:
    void accentColorChanged();

private:
    FakeConfiguration* m_config;
};
