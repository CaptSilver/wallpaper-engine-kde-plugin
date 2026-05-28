#pragma once
#include <QDBusConnection>
#include <QObject>
#include <QString>

namespace wekde
{

// D-Bus session-bus surface for headless control of the wallpaper engine.
// Service:   com.github.captsilver.WallpaperEngine
// Object:    /WallpaperEngine
// Interface: com.github.captsilver.WallpaperEngine
//
// All methods forward to the running QML PlaylistController via
// QMetaObject::invokeMethod; the C++ side is a thin adapter. See
// PlaylistController.qml for the QML-side export layer that this class
// invokes.
//
// Service ownership is first-plasmoid-wins on multi-monitor (the second
// plasmoid logs and goes silent). The owning plasmoid handles "Next" for
// the user. Per-monitor multi-instance D-Bus is a future spec.
class WekControl : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "com.github.captsilver.WallpaperEngine")

public:
    // Default constructor: lazy-registers on the session bus at construction.
    // Used by QML element instantiation. Silently no-ops on multi-monitor
    // secondaries (already-owned service) or environments without a session
    // bus.
    explicit WekControl(QObject* parent = nullptr);

    // Factory: registers on the session bus immediately. Returns nullptr if
    // the service is already owned (multi-monitor case) or the bus is
    // unavailable.
    static WekControl* registerOnSessionBus(QObject* parent = nullptr);

    // Test-only overload — accept an injected QDBusConnection so tests can
    // bring up a private peer-to-peer connection without dbus-launch.  Per
    // feedback_distrobox_dbus_launch_missing — neither dbus-launch nor
    // dbus-run-session ship in the Bazzite Fedora toolbox.
    static WekControl* registerOnConnection(QDBusConnection bus,
                                            QObject*        parent = nullptr);

    // True if the bus registration succeeded.  False on multi-monitor
    // secondaries, or when no session bus is available.
    bool isRegistered() const { return m_registered; }

    // Set by the QML root once PlaylistController.qml is created. Calls
    // before this is set silently no-op (the slot bodies check m_controller).
    Q_INVOKABLE void setPlaylistController(QObject* controller);

    // Bridge for QML-side WallpaperChanged emission — when the QML
    // PlaylistController detects a workshop-id transition, it calls this to
    // fire the D-Bus signal.
    Q_INVOKABLE void emitWallpaperChanged(const QString& workshopId,
                                          const QString& playlistId);

public slots:
    // Playlist navigation
    Q_NOREPLY void Next();
    Q_NOREPLY void Previous();
    Q_NOREPLY void Pause();
    Q_NOREPLY void Resume();
    Q_NOREPLY void Toggle();

    // Audio
    Q_NOREPLY void Mute();
    Q_NOREPLY void Unmute();
    Q_NOREPLY void ToggleMute();

    // Activation
    Q_NOREPLY void ActivatePlaylist(const QString& id);
    Q_NOREPLY void Reload();

    // Query (sync, returns a value — D-Bus method, not signal/property)
    QString CurrentWorkshopId() const;
    QString CurrentPlaylistId() const;
    int     CurrentItemIndex() const;

signals:
    // Broadcast on every wallpaper change. Third-party panel widgets
    // subscribe to this to update "now playing" displays.
    void WallpaperChanged(const QString& workshopId, const QString& playlistId);

private:
    // Private constructor for the static factories.
    WekControl(QObject* parent, QDBusConnection bus);

    bool registerOn(QDBusConnection& bus);

    QObject*        m_controller = nullptr;
    QDBusConnection m_bus;
    bool            m_registered = false;
};

} // namespace wekde
