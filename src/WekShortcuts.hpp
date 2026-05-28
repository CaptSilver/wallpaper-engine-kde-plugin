#pragma once
#include <QObject>

class KActionCollection;

namespace wekde
{

// Registers a KActionCollection of wallpaper-engine global shortcuts with
// KGlobalAccel.  All actions are default-unbound; the user binds them
// explicitly in System Settings -> Shortcuts -> Wallpaper Engine.
//
// On trigger, each action sends a D-Bus call to the WekControl interface
// (com.github.captsilver.WallpaperEngine) -- see WekControl.{hpp,cpp}.
// Decoupling here means multi-monitor installs work: the first plasmoid to
// register the D-Bus service handles the trigger; the other plasmoids'
// shortcut actions are silent owners of the same KActionCollection rows,
// which is harmless because KGlobalAccel dedupes by action id within a
// component name.
//
// Component id:           "wallpaper_engine"
// Component display name: "Wallpaper Engine"
//
// Action ids (visible in ~/.config/kglobalshortcutsrc):
//   next_wallpaper, previous_wallpaper, toggle_pause,
//   toggle_mute, reload_wallpaper, open_library
class WekShortcuts : public QObject {
    Q_OBJECT
public:
    explicit WekShortcuts(QObject* parent = nullptr);

    // Test hook -- exposes the underlying KActionCollection so tests can
    // assert action ids + labels.  Not part of the production API.
    KActionCollection* collectionForTest() const { return m_actions; }

private:
    KActionCollection* m_actions = nullptr;
};

} // namespace wekde
