// Tests for SafeWallpaperBridge — the C++ QWebChannel host object that
// replaces the inline QtObject `webobj`. Pins the contract:
//   * Q_PROPERTY surface is READ-only (no JS-side WRITE through QWebChannel).
//   * QML-only setters update the mirror + fire NOTIFY.
//   * Three signals: sigGeneralProperties / sigUserProperties / sigAudio.
//   * One one-shot init signal: sigInit (fired by QML on first
//     LoadSucceededStatus, replaces the page-injected wpeQml.loaded = true).
//   * No Q_INVOKABLE methods (web JS receives signals only).
//
// Real-world JS-write attempts are exercised in the QML integration test
// (tests/qml/tst_backend_qtwebview.qml) by re-targeting the inline-test
// bridge through QWebChannel — that's a Quick test, this file is the unit
// contract.

#include "SafeWallpaperBridge.hpp"

#include <QCoreApplication>
#include <QList>
#include <QObject>
#include <QSignalSpy>
#include <QTest>
#include <QVariantMap>

using wekde::SafeWallpaperBridge;

class TestSafeWallpaperBridge : public QObject {
    Q_OBJECT

private slots:
    void defaults_areEmptyAndUnloaded() {
        SafeWallpaperBridge b;
        QVERIFY(b.generalProperties().isEmpty());
        QVERIFY(b.userProperties().isEmpty());
        QCOMPARE(b.loaded(), false);
    }

    void pushGeneralProperties_updatesMirrorAndFiresNotify() {
        SafeWallpaperBridge b;
        QSignalSpy          notifySpy(&b, &SafeWallpaperBridge::generalPropertiesChanged);
        QSignalSpy          sigSpy(&b, &SafeWallpaperBridge::sigGeneralProperties);

        QVariantMap m;
        m["fps"] = 30;
        b.pushGeneralProperties(m);

        QCOMPARE(b.generalProperties().value("fps").toInt(), 30);
        QCOMPARE(notifySpy.count(), 1);
        // sigGeneralProperties is emitted alongside NOTIFY so QML consumers
        // and JS consumers see the same event. (Production fires the sig
        // signal explicitly in QtWebView.qml after each push; pin that here
        // to make the bridge self-consistent.)
        QCOMPARE(sigSpy.count(), 1);
        QCOMPARE(sigSpy.at(0).at(0).toMap().value("fps").toInt(), 30);
    }

    void pushUserProperties_updatesMirrorAndFiresNotify() {
        SafeWallpaperBridge b;
        QSignalSpy          notifySpy(&b, &SafeWallpaperBridge::userPropertiesChanged);
        QSignalSpy          sigSpy(&b, &SafeWallpaperBridge::sigUserProperties);

        QVariantMap m;
        QVariantMap slider;
        slider["value"] = 75;
        slider["type"]  = "slider";
        m["sliderProp"] = slider;
        b.pushUserProperties(m);

        QCOMPARE(b.userProperties().value("sliderProp").toMap().value("value").toInt(), 75);
        QCOMPARE(notifySpy.count(), 1);
        QCOMPARE(sigSpy.count(), 1);
    }

    void setLoaded_firesLoadedChangedAndSigInit_onlyOnFalseToTrue() {
        SafeWallpaperBridge b;
        QSignalSpy          notifySpy(&b, &SafeWallpaperBridge::loadedChanged);
        QSignalSpy          initSpy(&b, &SafeWallpaperBridge::sigInit);

        // First true: fires both.
        b.setLoaded(true);
        QCOMPARE(b.loaded(), true);
        QCOMPARE(notifySpy.count(), 1);
        QCOMPARE(initSpy.count(), 1);

        // Idempotent: setting true again does NOT re-fire (defends the
        // production handshake against double-init, since LoadSucceededStatus
        // can fire multiple times for in-page navs).
        b.setLoaded(true);
        QCOMPARE(notifySpy.count(), 1);
        QCOMPARE(initSpy.count(), 1);

        // false then true again: NOTIFY fires both transitions but sigInit
        // is one-shot for the lifetime of the bridge — once init has
        // happened, subsequent loaded toggles are page-level lifecycle
        // events (Frozen <-> Active) and the wallpaper JS doesn't expect
        // a fresh init handshake.
        b.setLoaded(false);
        QCOMPARE(notifySpy.count(), 2);
        QCOMPARE(initSpy.count(), 1);
        b.setLoaded(true);
        QCOMPARE(notifySpy.count(), 3);
        QCOMPARE(initSpy.count(), 1);
    }

    void sigAudio_emitsQListDoubleNotQVariantList() {
        // Audio uses QList<double> (zero-copy) per WebAudioBridge convention
        // (see WebAudioBridge::audioBuffer at WebAudioBridge.hpp). Pin the
        // type so a future refactor can't silently re-introduce per-tick
        // QVariantList heap boxes.
        SafeWallpaperBridge b;
        QSignalSpy          spy(&b, &SafeWallpaperBridge::sigAudio);

        QList<double> samples;
        for (int i = 0; i < 128; ++i) samples.append(double(i) / 128.0);
        emit b.sigAudio(samples);

        QCOMPARE(spy.count(), 1);
        // Compile-time pin: signal arg must round-trip via QList<double>.
        static_assert(
            std::is_same_v<decltype(std::declval<SafeWallpaperBridge>().sigAudio(samples)), void>);
    }

    // Defensive: confirm the meta-object has NO Q_INVOKABLE methods. A
    // future contributor adding one would silently widen the JS surface —
    // catch that at test-time, not in a security review.
    void metaObject_hasNoInvokableMethods() {
        SafeWallpaperBridge b;
        const QMetaObject*  mo             = b.metaObject();
        int                 invokableCount = 0;
        // Walk only the SafeWallpaperBridge slice (skip QObject base).
        for (int i = mo->methodOffset(); i < mo->methodCount(); ++i) {
            const QMetaMethod m = mo->method(i);
            if (m.methodType() == QMetaMethod::Method) {
                // Q_INVOKABLE shows up as MethodType::Method; signals show
                // as MethodType::Signal; slots as MethodType::Slot.
                ++invokableCount;
                qWarning() << "SafeWallpaperBridge has Q_INVOKABLE method:" << m.methodSignature();
            }
        }
        QCOMPARE(invokableCount, 0);
    }
};

QTEST_MAIN(TestSafeWallpaperBridge)
#include "tst_safewallpaperbridge.moc"
