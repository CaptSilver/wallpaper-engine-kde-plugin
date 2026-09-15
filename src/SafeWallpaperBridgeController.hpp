#pragma once
#include "SafeWallpaperBridge.hpp"
#include <QObject>
#include <QVariantMap>

namespace wekde
{

// QML-only forwarder onto SafeWallpaperBridge's plain-public setters.
//
// SafeWallpaperBridge's push*/setLoaded methods are deliberately NOT
// Q_INVOKABLE: QWebChannel marshals every Q_INVOKABLE method straight to the
// wallpaper's JS, so an invokable setter there is a setter the wallpaper
// itself can call. But a plain public C++ method is *also* invisible to
// QML — its property/method dispatch only reaches Q_PROPERTY, Q_INVOKABLE,
// and slots — so QML had nothing legal left to call and every web wallpaper
// died at load with a TypeError (issue #29).
//
// This object exists to plug exactly that gap and nothing more: its methods
// ARE Q_INVOKABLE (QML can call them), but it forwards straight to the
// bridge's existing C++ setters rather than duplicating their logic. It must
// NEVER be registered on a QWebChannel — doing so would hand the wallpaper
// back the same setters this whole split exists to keep out of its reach.
// QtWebView.qml wires it as a QML-only sibling of the channel-registered
// bridge, never inside registeredObjects.
class SafeWallpaperBridgeController : public QObject {
    Q_OBJECT
    Q_PROPERTY(wekde::SafeWallpaperBridge* bridge READ bridge WRITE setBridge NOTIFY bridgeChanged)

public:
    explicit SafeWallpaperBridgeController(QObject* parent = nullptr);
    ~SafeWallpaperBridgeController() override = default;

    SafeWallpaperBridge* bridge() const { return m_bridge; }
    void                 setBridge(SafeWallpaperBridge* bridge);

    // QML entry points. Each is a thin forward to the bridge; a null bridge
    // logs and drops the call rather than crashing (QtWebView.qml always
    // binds a real bridge, but nothing stops a stray QML instantiation from
    // skipping it).
    Q_INVOKABLE void setLoaded(bool loaded);
    Q_INVOKABLE void pushUserProperties(const QVariantMap& properties);
    Q_INVOKABLE void pushGeneralProperties(const QVariantMap& properties);

signals:
    void bridgeChanged();

private:
    SafeWallpaperBridge* m_bridge = nullptr;
};

} // namespace wekde
