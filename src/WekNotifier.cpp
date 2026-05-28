#include "WekNotifier.hpp"
#include <KNotification>
#include <QDebug>

namespace wekde
{

void WekNotifier::wallpaperLoadFailed(const QString& workshopId, const QString& reason) {
    auto* notification = new KNotification(QStringLiteral("wallpaperLoadFailed"));
    notification->setComponentName(QStringLiteral(kComponentName));
    notification->setTitle(QStringLiteral("Wallpaper could not be loaded"));
    notification->setText(QStringLiteral("Workshop entry %1 — %2").arg(workshopId, reason));
    notification->setIconName(QStringLiteral("dialog-warning"));
    notification->setDefaultAction(QStringLiteral("Open wallpaper settings"));
    QObject::connect(notification, &KNotification::defaultActivated, []() {
        // Plasma 6 doesn't expose an API to programmatically open the
        // containment wallpaper-config dialog. Log a hint; users can
        // right-click the desktop to reach the dialog.
        qInfo() << "[wek-notif] User clicked 'Open wallpaper settings'; "
                   "guide: right-click desktop → Configure Desktop and "
                   "Wallpaper.";
    });
    // Defensive: if KNotification errors on sendEvent (rare; bus down),
    // delete to prevent leak.
    QObject::connect(notification,
                     QOverload<KNotification::CloseReason>::of(&KNotification::closed),
                     notification,
                     &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::playlistAdvanced(const QString& workshopId, const QString& title, int itemIndex,
                                   int totalItems, const QString& playlistName) {
    Q_UNUSED(workshopId); // not embedded in user-visible text; available for future
    auto* notification = new KNotification(QStringLiteral("playlistAdvanced"));
    notification->setComponentName(QStringLiteral(kComponentName));
    notification->setTitle(QStringLiteral("Wallpaper changed in %1").arg(playlistName));
    notification->setText(
        QStringLiteral("%1 (item %2 of %3)").arg(title).arg(itemIndex).arg(totalItems));
    notification->setIconName(QStringLiteral("preferences-desktop-wallpaper"));
    QObject::connect(notification,
                     QOverload<KNotification::CloseReason>::of(&KNotification::closed),
                     notification,
                     &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::assetsMissing(const QString& workshopId, const QString& path) {
    auto* notification = new KNotification(QStringLiteral("assetsMissing"));
    notification->setComponentName(QStringLiteral(kComponentName));
    notification->setTitle(QStringLiteral("Wallpaper assets missing"));
    notification->setText(
        QStringLiteral("Workshop %1 — expected file not found at %2. "
                       "Re-subscribe from Steam Workshop, or remove from playlist.")
            .arg(workshopId, path));
    notification->setIconName(QStringLiteral("dialog-warning"));
    QObject::connect(notification,
                     QOverload<KNotification::CloseReason>::of(&KNotification::closed),
                     notification,
                     &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::backendUnavailable(const QString& backendName, const QString& reason) {
    auto* notification = new KNotification(QStringLiteral("backendUnavailable"));
    notification->setComponentName(QStringLiteral(kComponentName));
    notification->setTitle(QStringLiteral("Wallpaper backend not available"));
    notification->setText(QStringLiteral("%1 backend disabled: %2").arg(backendName, reason));
    notification->setIconName(QStringLiteral("dialog-error"));
    QObject::connect(notification,
                     QOverload<KNotification::CloseReason>::of(&KNotification::closed),
                     notification,
                     &QObject::deleteLater);
    notification->sendEvent();
}

} // namespace wekde
