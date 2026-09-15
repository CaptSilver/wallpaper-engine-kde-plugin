// Regression test for issue #29: SafeWallpaperBridge's push*/setLoaded
// methods are plain public C++ methods — deliberately not Q_INVOKABLE, so
// QWebChannel can't marshal them to web-wallpaper JS — but a plain public
// method is *also* unreachable from QML, whose method dispatch only sees
// Q_PROPERTY/Q_INVOKABLE/slots. QML had nothing legal left to call, so every
// web wallpaper died at load with a TypeError.
//
// SafeWallpaperBridgeController plugs that gap: its own setters ARE
// Q_INVOKABLE and forward straight to the bridge's C++ methods. This test
// drives it through a real QQmlEngine — not the C++ API directly — because a
// change that made the controller's methods QML-unreachable again (wrong
// signature, missing Q_INVOKABLE, wrong property type) would compile clean
// and pass a C++-only test while still leaving QML with nothing to call.

#include "SafeWallpaperBridge.hpp"
#include "SafeWallpaperBridgeController.hpp"

#include <QQmlComponent>
#include <QQmlEngine>
#include <QSignalSpy>
#include <QTest>
#include <QVariantMap>

using wekde::SafeWallpaperBridge;
using wekde::SafeWallpaperBridgeController;

class TestSafeWallpaperBridgeController : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        qmlRegisterType<SafeWallpaperBridge>("wekde.test", 1, 0, "SafeWallpaperBridge");
        qmlRegisterType<SafeWallpaperBridgeController>(
            "wekde.test", 1, 0, "SafeWallpaperBridgeController");
    }

    // The QML side declares the bridge + controller exactly the way
    // QtWebView.qml does (SafeWallpaperBridgeController { bridge: webobj }),
    // then calls the controller's setters from a QML function — standing in
    // for the JS call sites in production QML. Spies are attached to the
    // bridge's real C++ signals in between construction and the call, so a
    // regression that routes around the controller (or around the bridge's
    // signal-firing setters) shows up as a spy count mismatch, not just a
    // final-state check.
    void controllerReachesBridgeThroughQml() {
        QQmlEngine    engine;
        QQmlComponent component(&engine);
        component.setData(R"QML(
            import QtQuick
            import wekde.test 1.0

            QtObject {
                id: root
                property QtObject bridge: SafeWallpaperBridge {}
                property QtObject ctl: SafeWallpaperBridgeController { bridge: root.bridge }

                function driveFromJs() {
                    ctl.setLoaded(true);
                    ctl.pushUserProperties({ a: 1 });
                    ctl.pushGeneralProperties({ fps: 24 });
                }
            }
        )QML",
                          QUrl());

        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> root(component.create());
        QVERIFY(root != nullptr);

        auto* bridge =
            qobject_cast<SafeWallpaperBridge*>(root->property("bridge").value<QObject*>());
        QVERIFY(bridge != nullptr);

        QSignalSpy initSpy(bridge, &SafeWallpaperBridge::sigInit);
        QSignalSpy userPropsSpy(bridge, &SafeWallpaperBridge::sigUserProperties);
        QSignalSpy generalPropsSpy(bridge, &SafeWallpaperBridge::sigGeneralProperties);

        QVERIFY(QMetaObject::invokeMethod(root.data(), "driveFromJs"));

        QCOMPARE(bridge->loaded(), true);
        QCOMPARE(bridge->userProperties().value("a").toInt(), 1);
        QCOMPARE(bridge->generalProperties().value("fps").toInt(), 24);
        QCOMPARE(initSpy.count(), 1);
        QCOMPARE(userPropsSpy.count(), 1);
        QCOMPARE(generalPropsSpy.count(), 1);
    }

    // A null bridge must not crash the process — QtWebView.qml's controller
    // is bound to a static sibling so this never happens in production, but
    // a future caller (or a test harness) constructing the controller before
    // wiring `bridge` must get a loud no-op, not a segfault.
    void nullBridge_doesNotCrash_callsAreDropped() {
        SafeWallpaperBridgeController ctl;
        QVERIFY(ctl.bridge() == nullptr);
        ctl.setLoaded(true);
        ctl.pushUserProperties({ { "a", 1 } });
        ctl.pushGeneralProperties({ { "fps", 24 } });
        // Nothing to assert beyond "didn't crash" — there is no bridge to
        // observe state on.
    }
};

QTEST_MAIN(TestSafeWallpaperBridgeController)
#include "tst_safewallpaperbridgecontroller.moc"
