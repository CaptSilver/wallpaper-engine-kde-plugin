#pragma once
#include <QObject>
#include <QList>
#include <QVariantMap>

namespace wekde
{

// The ONLY QObject exposed to untrusted web-wallpaper JS via QWebChannel.
// Inline QML `QtObject` registrations leak default-writable properties to
// JS (a `property var` becomes a writable JS handle), so a wallpaper can
// poison its own property-delta path by writing back to .userProperties
// or re-fire the project.json load by toggling .loaded. A hand-rolled
// C++ wrapper pins every property as READ-only (no WRITE = no setter
// dispatched, JS-side writes silently no-op) and prevents future
// additions from silently widening the JS surface — any new method that
// would be web-callable requires an explicit Q_INVOKABLE annotation,
// which is grep-able and review-able.
//
// Contract:
//   * generalProperties / userProperties / loaded are READ-only from JS.
//     QML pushes via the public push*/setLoaded methods (not Q_INVOKABLE,
//     so QWebChannel does not marshal them).
//   * No Q_INVOKABLE methods anywhere — web JS receives signals only.
//     tst_safewallpaperbridge::metaObject_hasNoInvokableMethods pins this.
//   * Four signals reach web JS:
//       sigGeneralProperties(QVariantMap) — fps + plugin-level settings
//       sigUserProperties(QVariantMap)    — per-wallpaper user_properties
//       sigAudio(QList<double>)           — 128-element FFT spectrum
//                                           (matches WebAudioBridge zero-copy)
//       sigInit()                         — fired once when the bridge is
//                                           ready (replaces the page-injected
//                                           wpeQml.loaded = true writeback)
//
// SceneObject (the scene-renderer QQuickItem with the dangerous
// debugEvalJs/lsGet/lsSet/materialSetValue/etc. Q_INVOKABLEs) is NOT
// wired into any QWebChannel and MUST NEVER BE — web wallpapers must
// not reach SceneScript's QJSEngine. Keep this comment as a deterrent
// against well-meaning future extensions; backend/Scene.qml already
// carries the matching comment on the QML side.
class SafeWallpaperBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap generalProperties READ generalProperties NOTIFY generalPropertiesChanged)
    Q_PROPERTY(QVariantMap userProperties    READ userProperties    NOTIFY userPropertiesChanged)
    Q_PROPERTY(bool        loaded            READ loaded            NOTIFY loadedChanged)

public:
    explicit SafeWallpaperBridge(QObject* parent = nullptr);
    ~SafeWallpaperBridge() override = default;

    // Pure getters; called by QWebChannel + QML property bindings.
    QVariantMap generalProperties() const { return m_general; }
    QVariantMap userProperties() const { return m_user; }
    bool        loaded() const { return m_loaded; }

    // QML-only public setters. NOT Q_INVOKABLE — QWebChannel only
    // exposes Q_INVOKABLE methods to web JS, so a wallpaper cannot
    // call these. QML reaches them directly via the C++ type system
    // (no JSON marshal). Each updates the mirror + emits the matching
    // NOTIFY signal AND the corresponding sig* signal so JS-side
    // wallpapers and QML-side observers see the same event.
    void pushGeneralProperties(const QVariantMap& m);
    void pushUserProperties(const QVariantMap& m);
    void setLoaded(bool v);

signals:
    // NOTIFY signals — keep QML property bindings reactive.
    void generalPropertiesChanged();
    void userPropertiesChanged();
    void loadedChanged();
    // JS-facing signals — wallpapers connect via the QWebChannel handshake
    // (see backend/QtWebView.qml's WebEngineScript injection).
    void sigGeneralProperties(const QVariantMap& properties);
    void sigUserProperties(const QVariantMap& properties);
    void sigAudio(const QList<double>& samples);
    // One-shot init: fired by setLoaded(true) on the first false->true
    // transition. Replaces the page-injected `wpeQml.loaded = true`
    // writeback the legacy webobj relied on; the QML side now owns the
    // init handshake (fires from onLoadingChanged ==> LoadSucceededStatus).
    void sigInit();

private:
    QVariantMap m_general;
    QVariantMap m_user;
    bool        m_loaded { false };
    // Track whether sigInit has fired this lifetime so subsequent
    // loaded toggles (Frozen <-> Active lifecycle) don't re-fire init.
    bool        m_initFired { false };
};

} // namespace wekde
