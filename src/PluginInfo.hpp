#pragma once
#include <QObject>
#include <QUrl>

namespace wekde
{

class PluginInfo : public QObject {
    Q_OBJECT
    // Q_PROPERTY(READ WRITE NOTIFY)
    Q_PROPERTY(QUrl cache_path READ cache_path NOTIFY cache_pathChanged)
    Q_PROPERTY(QString version READ version CONSTANT)

public:
    explicit PluginInfo(QObject* parent = nullptr): QObject(parent) {}
    ~PluginInfo() override = default;

    QUrl cache_path() const;

    // Build-time version string injected by CMake via WEK_VERSION.
    // CONSTANT: the value is fixed at compile time and never changes at
    // runtime; no NOTIFY signal is needed or emitted.
    QString version() const { return QStringLiteral(WEK_VERSION); }

protected:
signals:
    void cache_pathChanged();
};
} // namespace wekde
