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
// Only one plasmoid answers the D-Bus call (multi-monitor: first to
// register the service), but that instance broadcasts the action to
// every screen's PlaylistController, so the shortcut reaches the whole
// desktop. The other plasmoids' shortcut actions are silent owners of
// the same KActionCollection rows -- harmless, since KGlobalAccel dedupes
// by action id within a component name, and the trigger still reaches
// every screen through the one instance that answers.
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
