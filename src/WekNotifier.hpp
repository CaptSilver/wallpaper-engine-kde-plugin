#pragma once
#include <QObject>
#include <QString>

namespace wekde {

// Thin C++ wrapper around KNotification — exposes four Q_INVOKABLE slots
// matching the [Event/...] groups in wek.notifyrc. Per-monitor dedup is
// handled at the QML caller side (only the primary-screen plasmoid invokes).
//
// KNotification self-deletes after Plasma's notification daemon processes
// the event; no manual deletion needed in the typical path. A defensive
// closed -> deleteLater connect catches the rare bus-down case.
class WekNotifier : public QObject {
    Q_OBJECT
public:
    explicit WekNotifier(QObject* parent = nullptr) : QObject(parent) {}

    // Event IDs match the [Event/<id>] groups in wek.notifyrc.
    Q_INVOKABLE void wallpaperLoadFailed(const QString& workshopId,
                                         const QString& reason);
    Q_INVOKABLE void playlistAdvanced(const QString& workshopId,
                                      const QString& title,
                                      int            itemIndex,
                                      int            totalItems,
                                      const QString& playlistName);
    Q_INVOKABLE void assetsMissing(const QString& workshopId,
                                   const QString& path);
    Q_INVOKABLE void backendUnavailable(const QString& backendName,
                                        const QString& reason);

private:
    // Component name for KNotification — matches wek.notifyrc filename
    // (without extension).
    static constexpr auto kComponentName = "wek";
};

} // namespace wekde
