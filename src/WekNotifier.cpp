#include "WekNotifier.hpp"
// KNotification header bundles the KNotificationAction class declaration;
// there is no separate <KNotificationAction> header in KF6 6.25.
#include <KLocalizedString>
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
    notification->setTitle(
        i18nc("@title notification, wallpaper failed to load", "Wallpaper could not be loaded"));
    notification->setText(i18nc("@info notification, %1=workshop id, %2=reason",
                                "Workshop entry %1 — %2",
                                workshopId,
                                reason));
    notification->setIconName(QStringLiteral("dialog-warning"));
    // KF6 6.x: addDefaultAction returns the action; the click is exposed via
    // KNotificationAction::activated, not via KNotification::defaultActivated
    // (the latter was removed in 6.x).
    auto* openSettings =
        notification->addDefaultAction(i18nc("@action:button", "Open wallpaper settings"));
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
    notification->setTitle(
        i18nc("@title notification, %1=playlist name", "Wallpaper changed in %1", playlistName));
    notification->setText(
        i18nc("@info notification, %1=wallpaper title, %2=item index, %3=total items",
              "%1 (item %2 of %3)",
              title,
              itemIndex,
              totalItems));
    notification->setIconName(QStringLiteral("preferences-desktop-wallpaper"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::assetsMissing(const QString& workshopId, const QString& path) {
    auto* notification = new KNotification(QStringLiteral("assetsMissing"));
    notification->setComponentName(componentName());
    notification->setTitle(
        i18nc("@title notification, wallpaper assets missing", "Wallpaper assets missing"));
    notification->setText(i18nc("@info notification, %1=workshop id, %2=path",
                                "Workshop %1 — expected file not found at %2. "
                                "Re-subscribe from Steam Workshop, or remove from playlist.",
                                workshopId,
                                path));
    notification->setIconName(QStringLiteral("dialog-warning"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::backendUnavailable(const QString& backendName, const QString& reason) {
    auto* notification = new KNotification(QStringLiteral("backendUnavailable"));
    notification->setComponentName(componentName());
    notification->setTitle(i18nc("@title notification, wallpaper backend not available",
                                 "Wallpaper backend not available"));
    notification->setText(i18nc("@info notification, %1=backend name, %2=reason",
                                "%1 backend disabled: %2",
                                backendName,
                                reason));
    notification->setIconName(QStringLiteral("dialog-error"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

void WekNotifier::wallpaperStillPaused() {
    auto* notification = new KNotification(QStringLiteral("wallpaperStillPaused"));
    notification->setComponentName(componentName());
    notification->setTitle(i18nc("@title notification, wallpaper still paused after restart",
                                 "Wallpaper still paused"));
    notification->setText(
        i18nc("@info notification, wallpaper still paused after restart",
              "The wallpaper was paused before the last restart and is still paused."));
    notification->setIconName(QStringLiteral("media-playback-pause"));
    QObject::connect(notification, &KNotification::closed, notification, &QObject::deleteLater);
    notification->sendEvent();
}

} // namespace wekde
