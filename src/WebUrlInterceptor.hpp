#pragma once
#include <QWebEngineUrlRequestInterceptor>
#include <QString>
#include <QUrl>

namespace wekde
{

// Per-wallpaper URL interceptor: blocks file:// requests that escape the
// canonical wallpaper baseUrl directory (recursive, symlink-resolved).
// Non-file schemes (http(s), data:, blob:, qrc:) pass through unchanged so
// Workshop wallpapers can still hit CDNs / fonts / weather APIs.
class WebUrlInterceptor : public QWebEngineUrlRequestInterceptor {
    Q_OBJECT
public:
    explicit WebUrlInterceptor(QObject* parent = nullptr);

    // Install this interceptor on a QML WebEngineProfile.  Qt 6 exposes no
    // QML-assignable `urlRequestInterceptor` property — the only entry point is
    // QQuickWebEngineProfile::setUrlRequestInterceptor() in C++ — so QML calls
    // this from the profile's Component.onCompleted.  `profile` is the QML
    // WebEngineProfile object; a non-profile argument logs loudly and no-ops
    // (the file:// sandbox is then inactive rather than silently mis-wired).
    Q_INVOKABLE void installOn(QObject* profile);

    // Called from QML before loadHtml() with the wallpaper's directory path
    // (a native local-filesystem path, not a file:// URL).  Empty string
    // resets the gate to "block all file:// requests".
    Q_INVOKABLE void setWallpaperBaseDir(const QString& baseDirPath);

    // Pure predicate — extracted so unit tests can exhaustively cover the
    // allow/block matrix without constructing QWebEngineUrlRequestInfo
    // (which is opaque outside Chromium).
    bool isAllowed(const QUrl& url) const;

    void interceptRequest(QWebEngineUrlRequestInfo& info) override;

private:
    QString m_canonicalBaseDir;
};

} // namespace wekde
