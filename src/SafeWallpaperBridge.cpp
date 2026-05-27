#include "SafeWallpaperBridge.hpp"

namespace wekde
{

SafeWallpaperBridge::SafeWallpaperBridge(QObject* parent): QObject(parent) {}

void SafeWallpaperBridge::pushGeneralProperties(const QVariantMap& m) {
    m_general = m;
    emit generalPropertiesChanged();
    // Emit the JS-facing signal too so wallpapers connected to
    // sigGeneralProperties see the update without QML having to fire it
    // separately. Matches the legacy webobj behaviour (QtWebView.qml
    // fires webobj.sigGeneralProperties(webobj.generalProperties) after
    // every onFpsChanged) but folded into the bridge so the QML side
    // can't accidentally drop one of the two emits.
    emit sigGeneralProperties(m_general);
}

void SafeWallpaperBridge::pushUserProperties(const QVariantMap& m) {
    m_user = m;
    emit userPropertiesChanged();
    emit sigUserProperties(m_user);
}

void SafeWallpaperBridge::setLoaded(bool v) {
    if (m_loaded == v) return; // dedupe redundant transitions
    m_loaded = v;
    emit loadedChanged();
    // One-shot init: only fire on the FIRST false->true transition this
    // lifetime. Subsequent toggles are page-lifecycle events (lifecycle
    // freeze/thaw) and the wallpaper JS does not expect a fresh handshake.
    if (v && ! m_initFired) {
        m_initFired = true;
        emit sigInit();
    }
}

} // namespace wekde
