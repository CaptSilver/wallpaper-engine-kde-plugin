#include "WebUrlInterceptor.hpp"
#include <QWebEngineUrlRequestInfo>
#include <QFileInfo>
#include <QDir>
#include <QLoggingCategory>

namespace wekde
{

WebUrlInterceptor::WebUrlInterceptor(QObject* parent)
    : QWebEngineUrlRequestInterceptor(parent) {}

void WebUrlInterceptor::setWallpaperBaseDir(const QString& baseDirPath) {
    if (baseDirPath.isEmpty()) {
        m_canonicalBaseDir.clear();
        return;
    }
    m_canonicalBaseDir = QFileInfo(baseDirPath).canonicalFilePath();
}

bool WebUrlInterceptor::isAllowed(const QUrl& url) const {
    const QString scheme = url.scheme();
    // Non-file schemes pass through; existing wallpapers rely on HTTPS / data
    // / blob / qrc for CDN fonts, weather APIs, embedded images, qwebchannel.
    if (scheme != QLatin1String("file")) return true;
    // file:// before any wallpaper has been loaded: block (defensive default).
    if (m_canonicalBaseDir.isEmpty()) return false;

    // Normalise before canonicalisation so URL-encoded `..` segments and
    // raw `..` traversals collapse to the same form QFileInfo sees.
    const QString local     = QDir::cleanPath(url.toLocalFile());
    const QString requested = QFileInfo(local).canonicalFilePath();
    if (requested.isEmpty()) return false;

    // Allow the base directory itself OR any path beneath base + '/'.
    // The trailing-slash check defeats sibling-prefix bypass
    // (/tmp/wp vs /tmp/wp-evil).
    if (requested == m_canonicalBaseDir) return true;
    const QString prefix = m_canonicalBaseDir.endsWith('/')
        ? m_canonicalBaseDir
        : m_canonicalBaseDir + QLatin1Char('/');
    return requested.startsWith(prefix);
}

void WebUrlInterceptor::interceptRequest(QWebEngineUrlRequestInfo& info) {
    const QUrl url = info.requestUrl();
    if (! isAllowed(url)) {
        qWarning() << "[WEK] interceptor: blocked out-of-scope" << url.scheme()
                   << url.toString() << "(base" << m_canonicalBaseDir << ")";
        info.block(true);
    }
}

} // namespace wekde
