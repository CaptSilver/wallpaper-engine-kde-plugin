#pragma once
#include <QString>

namespace wekde
{

// True when `applicationName` is the process that hosts the wallpaper itself.
// Other hosts (System Settings, kcmshell) only load the plugin for its
// settings page, and per-process setup that drives the running wallpaper --
// the global shortcuts -- belongs to plasmashell alone.
inline bool HostsWallpapers(const QString& applicationName) {
    return applicationName == QLatin1String("plasmashell");
}

} // namespace wekde
