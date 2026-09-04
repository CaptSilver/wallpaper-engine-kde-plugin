#include "WekShortcuts.hpp"

#include <KActionCollection>
#include <KGlobalAccel>
#include <QAction>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QString>

namespace wekde
{

namespace
{

// Send an async D-Bus method call to the WekControl service (the C++ adapter
// over the QML PlaylistController).  Async because the action's triggered()
// signal lives on the UI thread and we don't want to block on a method
// response.  Errors are silent: the call is addressed by bus name, so
// whichever plasmoid owns the surface answers it no matter how many screens
// are up; with no wallpaper plasmoid running there is no owner and the call
// goes nowhere.
void invokeDBusMethod(const QString& method) {
    auto msg =
        QDBusMessage::createMethodCall(QStringLiteral("com.github.captsilver.WallpaperEngine"),
                                       QStringLiteral("/WallpaperEngine"),
                                       QStringLiteral("com.github.captsilver.WallpaperEngine"),
                                       method);
    QDBusConnection::sessionBus().asyncCall(msg);
}

} // namespace

WekShortcuts::WekShortcuts(QObject* parent)
    : QObject(parent), m_actions(new KActionCollection(this, QStringLiteral("wallpaper_engine"))) {
    m_actions->setComponentDisplayName(QStringLiteral("Wallpaper Engine"));

    // Helper: create the action, default-unbind via setGlobalShortcut({}),
    // and wire its triggered() to the async D-Bus call.
    auto registerAction =
        [this](const QString& id, const QString& label, const QString& dbusMember) -> QAction* {
        auto* action = m_actions->addAction(id);
        action->setText(label);
        // Default-unbound -- KDE convention.  User binds via System Settings.
        KGlobalAccel::self()->setGlobalShortcut(action, QList<QKeySequence> {});
        QObject::connect(action, &QAction::triggered, this, [dbusMember]() {
            invokeDBusMethod(dbusMember);
        });
        return action;
    };

    registerAction(QStringLiteral("next_wallpaper"),
                   QStringLiteral("Next wallpaper in playlist"),
                   QStringLiteral("Next"));

    registerAction(QStringLiteral("previous_wallpaper"),
                   QStringLiteral("Previous wallpaper in playlist"),
                   QStringLiteral("Previous"));

    registerAction(QStringLiteral("toggle_pause"),
                   QStringLiteral("Pause / resume wallpaper"),
                   QStringLiteral("Toggle"));

    registerAction(QStringLiteral("toggle_mute"),
                   QStringLiteral("Toggle wallpaper audio mute"),
                   QStringLiteral("ToggleMute"));

    registerAction(QStringLiteral("reload_wallpaper"),
                   QStringLiteral("Reload current wallpaper"),
                   QStringLiteral("Reload"));

    // open_library opens the config dialog.  No clean Plasma 6 API exists to
    // programmatically open a containment-owned dialog, so this one logs a
    // hint rather than D-Bus dispatch.  Revisit when Plasma 6.x adds an
    // openWallpaperConfig signal.
    auto* openLib = m_actions->addAction(QStringLiteral("open_library"));
    openLib->setText(QStringLiteral("Open wallpaper library (configuration dialog)"));
    KGlobalAccel::self()->setGlobalShortcut(openLib, QList<QKeySequence> {});
    QObject::connect(openLib, &QAction::triggered, this, []() {
        qInfo("wek-shortcuts: 'Open Library' shortcut triggered; user "
              "should right-click desktop -> Configure Desktop and "
              "Wallpaper...");
    });
}

} // namespace wekde
