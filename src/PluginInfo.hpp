#pragma once
#include <QObject>
#include <QUrl>

namespace wekde
{

class PluginInfo : public QObject {
    Q_OBJECT
    // CONSTANT: the cache path is synthesised from $XDG_CACHE_HOME and the
    // submodule name (see SceneObject::GetDefaultCachePath); both are fixed
    // at process start so there is no setter path and no signal to emit.
    Q_PROPERTY(QUrl cache_path READ cache_path CONSTANT)
    Q_PROPERTY(QString version READ version CONSTANT)

public:
    explicit PluginInfo(QObject* parent = nullptr): QObject(parent) {}
    ~PluginInfo() override = default;

    QUrl cache_path() const;

    // Build-time version string injected by CMake via WEK_VERSION.
    // CONSTANT: the value is fixed at compile time and never changes at
    // runtime; no NOTIFY signal is needed or emitted.
    QString version() const { return QStringLiteral(WEK_VERSION); }
};
} // namespace wekde
