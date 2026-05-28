#include "WekNotifier.hpp"
// KNotification header bundles the KNotificationAction class declaration;
// there is no separate <KNotificationAction> header in KF6 6.25.
#include <KNotification>
#include <QDebug>

namespace wekde
{

namespace
{
// Component name resolves to the same string the KF6 daemon expects to find
// `wek.notifyrc` under.  KNotification::setComponentName takes a QString, and
// QStringLiteral wraps a literal at preprocessor time — it cannot consume a
// `constexpr auto kComponentName = "wek"` symbol.  QString::fromUtf8 over the
// static `const char*` produces the same QString at one extra (tiny) cost per
// notification.
inline QString componentName() { return QString::fromUtf8(WekNotifier::componentNameLiteral()); }
} // namespace

void WekNotifier::wallpaperLoadFailed(const QString& workshopId, const QString& reason) {
    auto* notification = new KNotification(QStringLiteral("wallpaperLoadFailed"));
    notification->setComponentName(componentName());
    notification->setTitle(QStringLiteral("Wallpaper could not be loaded"));
    notification->setText(QStringLiteral("Workshop entry %1 — %2").arg(workshopId, reason));
    notification->setIconName(QStringLiteral("dialog-warning"));
    // KF6 6.x: addDefaultAction returns the action; the click is exposed via
    // KNotificationAction::activated, not via KNotification::defaultActivated
    // (the latter was removed in 6.x).
    auto* openSettings = notification->addDefaultAction(QStringLiteral("Open wallpaper settings"));
    QObject::connect(openSettings, &KNotificationAction::activated, []() {
        // Plasma 6 doesn't expose an API to programmatically open the
        // containment wallpaper-config dialog. Log a hint; users can
        // right-click the desktop to reach the dialog.
        qInfo() << "[wek-notif] User clicked 'Open wallpaper settings'; "
                   "guide: right-click desktop → Configure Desktop and "
                   "Wallpaper.";
    });
    // Defensive: if KNotification errors on sendEvent (rare; bus down), delete
    // to prevent leak.  KF6 6.x KNotification::closed() takes no parameter.
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::playlistAdvanced(const QString& workshopId, const QString& title, int itemIndex,
                                   int totalItems, const QString& playlistName) {
    Q_UNUSED(workshopId); // not embedded in user-visible text; available for future
    auto* notification = new KNotification(QStringLiteral("playlistAdvanced"));
    notification->setComponentName(componentName());
    notification->setTitle(QStringLiteral("Wallpaper changed in %1").arg(playlistName));
    notification->setText(
        QStringLiteral("%1 (item %2 of %3)").arg(title).arg(itemIndex).arg(totalItems));
    notification->setIconName(QStringLiteral("preferences-desktop-wallpaper"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::assetsMissing(const QString& workshopId, const QString& path) {
    auto* notification = new KNotification(QStringLiteral("assetsMissing"));
    notification->setComponentName(componentName());
    notification->setTitle(QStringLiteral("Wallpaper assets missing"));
    notification->setText(
        QStringLiteral("Workshop %1 — expected file not found at %2. "
                       "Re-subscribe from Steam Workshop, or remove from playlist.")
            .arg(workshopId, path));
    notification->setIconName(QStringLiteral("dialog-warning"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::backendUnavailable(const QString& backendName, const QString& reason) {
    auto* notification = new KNotification(QStringLiteral("backendUnavailable"));
    notification->setComponentName(componentName());
    notification->setTitle(QStringLiteral("Wallpaper backend not available"));
    notification->setText(QStringLiteral("%1 backend disabled: %2").arg(backendName, reason));
    notification->setIconName(QStringLiteral("dialog-error"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

} // namespace wekde
