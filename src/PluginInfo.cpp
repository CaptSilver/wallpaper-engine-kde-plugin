#include "PluginInfo.hpp"
#include <QCoreApplication>

#include "SceneBackend.hpp"

using namespace wekde;

QUrl PluginInfo::cache_path() const {
    return QUrl::fromLocalFile(
        QString::fromStdString(scenebackend::SceneObject::GetDefaultCachePath()));
}
