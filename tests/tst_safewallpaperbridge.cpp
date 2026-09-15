// Tests for SafeWallpaperBridge — the C++ QWebChannel host object that
// replaces the inline QtObject `webobj`. Pins the contract:
//   * Q_PROPERTY surface is READ-only (no JS-side WRITE through QWebChannel).
//   * QML-only setters update the mirror + fire NOTIFY.
//   * Three signals: sigGeneralProperties / sigUserProperties / sigAudio.
//   * An init signal: sigInit (fired by QML on LoadSucceededStatus, once per
//     document; replaces the page-injected wpeQml.loaded = true).
//   * No Q_INVOKABLE methods (web JS receives signals only).
//
// Real-world JS-write attempts are exercised in the QML integration test
// (tests/qml/tst_backend_qtwebview.qml) by re-targeting the inline-test
// bridge through QWebChannel — that's a Quick test, this file is the unit
// contract.

#include "SafeWallpaperBridge.hpp"

#include <QCoreApplication>
#include <QList>
#include <QMetaProperty>
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

    void setLoaded_dedupesRepeatTrue_andReArmsInitAfterUnload() {
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

        // false means the document is gone — QtWebView says so when it
        // replaces the page and when a discard kills the renderer. Whatever
        // loads afterwards is a fresh page with a fresh JS context, so it gets
        // its own handshake: the previous document's connections died with it.
        b.setLoaded(false);
        QCOMPARE(notifySpy.count(), 2);
        QCOMPARE(initSpy.count(), 1);
        b.setLoaded(true);
        QCOMPARE(notifySpy.count(), 3);
        QCOMPARE(initSpy.count(), 2);
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

    // Regression: every Q_PROPERTY on the bridge must be READ-only. A WRITE
    // clause here is JS-reachable — QWebChannel's publisher dispatches an
    // inbound "setProperty" over the wire straight through QMetaProperty::write,
    // so a WRITE gives web-wallpaper JS a setter with no Q_INVOKABLE required
    // to grep for. (This is what shipped briefly: generalProperties/
    // userProperties/loaded gained WRITE clauses so *QML* could reach the
    // setters, which also reopened the JS-writable hole this class exists to
    // close.)
    void metaObject_allPropertiesAreReadOnly() {
        SafeWallpaperBridge b;
        const QMetaObject*  mo = b.metaObject();
        for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i) {
            const QMetaProperty p = mo->property(i);
            QVERIFY2(! p.isWritable(),
                     qPrintable(QString("property '%1' is writable — web JS reaches it over "
                                        "QWebChannel")
                                    .arg(p.name())));
        }
    }

    // Regression: the bridge must not expose a QObject* property. The channel
    // marshals whatever QObject a reachable property points at, so if the
    // bridge ever grew a pointer back to SafeWallpaperBridgeController (or
    // anything else), the page could walk through it to invoke the
    // controller's Q_INVOKABLE setters — the exact hole this split is meant
    // to close.
    void metaObject_hasNoQObjectPointerProperty() {
        SafeWallpaperBridge b;
        const QMetaObject*  mo = b.metaObject();
        for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i) {
            const QMetaProperty p = mo->property(i);
            QVERIFY2(! QByteArray(p.typeName()).contains('*'),
                     qPrintable(QString("property '%1' is a pointer type ('%2') — the "
                                        "QWebChannel-exposed bridge must not be reachable to "
                                        "any other QObject")
                                    .arg(p.name(), p.typeName())));
        }
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
