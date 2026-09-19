#pragma once
#include <QObject>
#include <QString>

namespace wekde
{

// One browser context per wallpaper, keyed on its workshop id: its own
// storage directory, its own file:// gate. That used to mean one QML
// `WebEngineProfile {}` built fresh per view -- but Qt never shares a
// context by name, so two profile objects that land on the same
// storageName are two contexts pointed at one on-disk directory, and
// whichever one starts loading second silently stalls (no error, just a
// load that never leaves LoadStartedStatus), wedging that name for the rest
// of the process. Two views can easily want the same wallpaper's profile
// alive at once: the same web wallpaper on two monitors, or a web-to-web
// swap, where main.qml's loader keeps the outgoing backend (and its
// profile) alive for up to 100 ms after the incoming one is created. This
// class fixes that by handing every view of a wallpaper the SAME live
// QQuickWebEngineProfile, looked up by workshop id instead of built fresh
// per view.
//
// The table backing this is a function-local static, not a QML singleton:
// a singleton is per-QQmlEngine, and this plugin runs inside several engines
// in one process (one per containment in plasmashell; qmltestrunner starts a
// fresh engine per test file), so a per-engine table would still let two
// engines build two profiles on one name.
class WebProfileRegistry : public QObject {
    Q_OBJECT
public:
    explicit WebProfileRegistry(QObject* parent = nullptr);

    // "wek-wp-" + workshopId with every character outside [A-Za-z0-9_-]
    // removed; "wek-wp-local" when nothing survives (no id, or an id that
    // is entirely punctuation / non-ASCII). Mirrors the sanitizing rule
    // QtWebView.qml used to apply inline.
    static QString storageNameFor(const QString& workshopId);

    // The one profile for workshopId's storage name, created on first
    // request and returned unchanged after that. Never two objects for one
    // name.
    Q_INVOKABLE QObject* profileFor(const QString& workshopId);

    // The WebUrlInterceptor bound to that profile's file:// gate, created
    // alongside the profile the first time either is requested for a name.
    Q_INVOKABLE QObject* interceptorFor(const QString& workshopId);

    // Test seam: number of distinct profiles this process has created.
    Q_INVOKABLE int liveProfileCount() const;
};

} // namespace wekde
