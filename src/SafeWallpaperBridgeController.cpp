#include "SafeWallpaperBridgeController.hpp"

#include <QDebug>

namespace wekde
{

SafeWallpaperBridgeController::SafeWallpaperBridgeController(QObject* parent): QObject(parent) {}

void SafeWallpaperBridgeController::setBridge(SafeWallpaperBridge* bridge) {
    if (m_bridge == bridge) return;
    m_bridge = bridge;
    emit bridgeChanged();
}

void SafeWallpaperBridgeController::setLoaded(bool loaded) {
    if (! m_bridge) {
        qWarning() << "SafeWallpaperBridgeController::setLoaded: no bridge bound, dropping call";
        return;
    }
    m_bridge->setLoaded(loaded);
}

void SafeWallpaperBridgeController::pushUserProperties(const QVariantMap& properties) {
    if (! m_bridge) {
        qWarning() << "SafeWallpaperBridgeController::pushUserProperties: no bridge bound, "
                      "dropping call";
        return;
    }
    m_bridge->pushUserProperties(properties);
}

void SafeWallpaperBridgeController::pushGeneralProperties(const QVariantMap& properties) {
    if (! m_bridge) {
        qWarning() << "SafeWallpaperBridgeController::pushGeneralProperties: no bridge bound, "
                      "dropping call";
        return;
    }
    m_bridge->pushGeneralProperties(properties);
}

} // namespace wekde
