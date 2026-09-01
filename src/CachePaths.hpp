#pragma once
#include <QFileInfo>
#include <QStandardPaths>
#include <QString>

#include <string_view>

#include "Utils/Platform.hpp"

namespace wekde
{
namespace cache_paths
{

inline QString fromView(std::string_view v) {
    return QString::fromUtf8(v.data(), static_cast<qsizetype>(v.size()));
}

// Root of every cache-maintenance guard in the plugin.
//
// NOT QStandardPaths::CacheLocation: that appends the *host application*
// name, so inside plasmashell it resolves to ~/.cache/plasmashell while the
// renderer builds its cache dir straight from $XDG_CACHE_HOME with no
// application segment (platform::GetCachePath). The two are siblings, so a
// guard rooted at CacheLocation can never accept a path any caller passes.
//
// Empty when the directory doesn't exist yet — callers must treat that as
// "refuse", never as "no constraint".
inline QString userCacheRoot() {
    return QFileInfo(QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation))
        .canonicalFilePath();
}

// Naming a location, as opposed to guarding one: falls back to the
// uncanonicalised root so these still answer before ~/.cache exists. Never
// use this as a guard root — userCacheRoot() is the one that refuses when it
// cannot resolve.
inline QString userCacheRootPath() {
    const QString canon = userCacheRoot();
    if (! canon.isEmpty()) return canon;
    return QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
}

// Where the scene renderer keeps compiled shaders and per-scene state, and
// where the Vulkan pipeline cache + its diagnostics dump live. Both names
// come from the renderer (Utils/Platform.hpp) — the plugin only supplies
// Qt's idea of the user cache root.
inline QString rendererCacheDir() {
    const QString root = userCacheRootPath();
    if (root.isEmpty()) return {};
    return root + QLatin1Char('/') + fromView(wallpaper::platform::kRendererCacheDir);
}

inline QString pipelineCacheDir() {
    const QString root = userCacheRootPath();
    if (root.isEmpty()) return {};
    return root + QLatin1Char('/') + fromView(wallpaper::platform::kPipelineCacheDir);
}

// Where diagnostic bundles are written. Deliberately its own directory: the
// bundles used to land in the same place the cache manifest walked, so every
// bug report's manifest described the previous bug report instead of the
// renderer cache.
inline QString diagnosticsDir() {
    const QString root = userCacheRootPath();
    if (root.isEmpty()) return {};
    return root + QStringLiteral("/wekde/diagnostics");
}

// True for files that live under the cache root but are user data, not cache.
// SceneScript's localStorage is written by the wallpaper and never
// regenerated, so deleting it loses whatever the scene saved (icon layouts,
// counters, game progress). Matched by basename because the per-scene copy
// sits in an arbitrary <sceneId>/ subdirectory.
inline bool isPreservedCacheFile(const QString& path) {
    const QString name = QFileInfo(path).fileName();
    return name == fromView(wallpaper::platform::kLocalStorageGlobalFile) ||
           name == fromView(wallpaper::platform::kLocalStorageSceneFile);
}

} // namespace cache_paths
} // namespace wekde
