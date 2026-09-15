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
//     QML pushes through SafeWallpaperBridgeController, a QML-only type
//     that is never registered on the channel and forwards to the plain
//     public push*/setLoaded methods (not Q_INVOKABLE, not slots, so
//     QWebChannel does not publish them).
//     tst_safewallpaperbridge::metaObject_allPropertiesAreReadOnly pins
//     the no-WRITE half of this.
//   * No Q_INVOKABLE methods anywhere — web JS receives signals only.
//     tst_safewallpaperbridge::metaObject_hasNoInvokableMethods pins this.
//   * Four signals reach web JS:
//       sigGeneralProperties(QVariantMap) — fps + plugin-level settings
//       sigUserProperties(QVariantMap)    — per-wallpaper user_properties
//       sigAudio(QList<double>)           — 128-element FFT spectrum
//                                           (matches WebAudioBridge zero-copy)
//       sigInit()                         — fired once per loaded document
//                                           (replaces the page-injected
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
    Q_PROPERTY(QVariantMap userProperties READ userProperties NOTIFY userPropertiesChanged)
    Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)

public:
    explicit SafeWallpaperBridge(QObject* parent = nullptr);
    ~SafeWallpaperBridge() override = default;

    // Pure getters; called by QWebChannel + QML property bindings.
    QVariantMap generalProperties() const { return m_general; }
    QVariantMap userProperties() const { return m_user; }
    bool        loaded() const { return m_loaded; }

    // Plain public setters: not Q_INVOKABLE, not slots, and no WRITE on
    // the properties above — QWebChannel publishes all three of those to
    // page JS, so any of them would let a wallpaper write its own state.
    // QML cannot call plain methods either; SafeWallpaperBridgeController
    // (a QML type that is never registered on the channel) is what
    // forwards to these. Each updates the mirror + emits the matching
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
    // Init handshake: fired by setLoaded(true) on a false->true transition,
    // once per document. Replaces the page-injected `wpeQml.loaded = true`
    // writeback the legacy webobj relied on; the QML side now owns the
    // init handshake (fires from onLoadingChanged ==> LoadSucceededStatus).
    void sigInit();

private:
    QVariantMap m_general;
    QVariantMap m_user;
    bool        m_loaded { false };
    // Track whether sigInit has fired for the CURRENT document, so repeat
    // LoadSucceededStatus reports (in-page navs) don't re-fire init.
    // setLoaded(false) clears it — that is QtWebView telling us the document
    // is gone.
    bool m_initFired { false };
};

} // namespace wekde
