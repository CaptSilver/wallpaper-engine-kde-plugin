// WebProfileRegistry is the fix for a silent web-wallpaper stall: every QML
// WebEngineProfile builds its own Chromium BrowserContext, so two profile
// objects that happen to share a storageName are two contexts pointed at one
// on-disk directory, and the second one to start loading never finishes.
// main.qml's backend swap keeps the outgoing backend (and its profile) alive
// for up to 100 ms after the incoming one is created, so a fast web-to-web
// switch, two monitors on the same web wallpaper, or an A-B-A switch all used
// to hit that overlap. The fix is one live profile per storage name, shared
// by every view, so these tests exist to prove there is never a second one.
//
// Needs a custom main(): QtWebEngineQuick::initialize() must run before the
// QGuiApplication is constructed, which QTEST_MAIN's generated main() cannot
// do for us.

#include "TestSandbox.h"
#include "WebProfileRegistry.hpp"
#include "WebUrlInterceptor.hpp"

#include <QDirIterator>
#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWebEngineProfile>
#include <QScopedPointer>
#include <QTest>
#include <QVariantMap>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

using wekde::WebProfileRegistry;
using wekde::WebUrlInterceptor;

namespace
{

// QQuickWebEngineProfile has no public getter for the interceptor passed to
// setUrlRequestInterceptor() (checked the Qt 6.11 header), so "installed on
// the profile" can't be read back from the profile object. What IS checkable
// from outside: interceptorFor() always hands back the one interceptor that
// exists for a name, and that object actually gates file:// requests --
// together that's proof profileFor()'s internal wiring is doing its job,
// not just that some WebUrlInterceptor got constructed.
void assertInterceptorGatesFileScheme(QObject* interceptorObj) {
    auto* interceptor = qobject_cast<WebUrlInterceptor*>(interceptorObj);
    QVERIFY(interceptor != nullptr);
    QVERIFY(! interceptor->isAllowed(QUrl::fromLocalFile("/etc/passwd")));
    interceptor->setWallpaperBaseDir("/tmp");
    // isAllowed canonicalizes the requested path, which requires it to
    // exist on disk -- "/tmp" itself always does, an arbitrary child
    // wouldn't (see tst_weburlinterceptor.cpp's isAllowed_baseItself_allowed).
    QVERIFY(interceptor->isAllowed(QUrl::fromLocalFile("/tmp")));
    QVERIFY(interceptor->isAllowed(QUrl("https://example.com/")));
}

// Qt substitutes its own global "Default" profile (and creates a
// QtWebEngine/Default directory for it) the moment a WebEngineView's
// componentComplete() runs with no real profile bound yet -- see
// QtWebView.qml's comment on the Binding element for the construction-order
// reasoning this guards against. Every profile this test suite builds
// through the registry gets an explicit non-"Default" storage name, so
// finding this directory under the isolated HOME can only mean Qt's own
// substitution kicked in.
bool homeContainsDefaultProfileDir(const QString& home) {
    QDirIterator it(home,
                    QStringList { QStringLiteral("Default") },
                    QDir::Dirs | QDir::NoDotAndDotDot,
                    QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString path = it.next();
        if (QFileInfo(path).dir().dirName() == QLatin1String("QtWebEngine")) return true;
    }
    return false;
}

} // namespace

class TestWebProfileRegistry : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Give the process its own HOME so the profiles this test creates
        // don't collide with another test binary's (or a live plasmashell's)
        // ~/.local/share/plasmashell/QtWebEngine/wek-wp-* directories.
        wek::test_sandbox::enableIsolated();
        qmlRegisterType<WebProfileRegistry>("wekde.test", 1, 0, "WebProfileRegistry");
    }

    void storageNameFor_sanitizesAndFallsBackToLocal() {
        QCOMPARE(WebProfileRegistry::storageNameFor("123"), QStringLiteral("wek-wp-123"));
        QCOMPARE(WebProfileRegistry::storageNameFor(""), QStringLiteral("wek-wp-local"));
        QCOMPARE(WebProfileRegistry::storageNameFor("a/b c"), QStringLiteral("wek-wp-abc"));
        // Non-ASCII survives nothing in the [A-Za-z0-9_-] filter, so it
        // collapses to the same bucket as "no id at all".
        QCOMPARE(WebProfileRegistry::storageNameFor(
                     QString::fromUtf8("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e")),
                 QStringLiteral("wek-wp-local"));
    }

    void profileFor_sameId_returnsSameConfiguredProfile() {
        WebProfileRegistry reg;
        auto*              first  = reg.profileFor("t-same-config");
        auto*              second = reg.profileFor("t-same-config");
        QCOMPARE(first, second);

        auto* profile = qobject_cast<QQuickWebEngineProfile*>(first);
        QVERIFY(profile != nullptr);
        QCOMPARE(profile->storageName(), QStringLiteral("wek-wp-t-same-config"));
        QCOMPARE(profile->isOffTheRecord(), false);
        QCOMPARE(profile->httpCacheType(), QQuickWebEngineProfile::DiskHttpCache);
        QCOMPARE(profile->httpCacheMaximumSize(), 50 * 1024 * 1024);
    }

    void profileFor_differentIds_returnDifferentObjects() {
        WebProfileRegistry reg;
        auto*              a = reg.profileFor("t-diff-a");
        auto*              b = reg.profileFor("t-diff-b");
        QVERIFY(a != b);
    }

    void profileFor_sharedAcrossSeparateRegistryInstances() {
        // Two facades, one process-wide table: this is what makes sharing
        // work when main.qml creates a fresh QtWebView.qml (and with it a
        // fresh WebProfileRegistry {} element) on every backend swap.
        WebProfileRegistry regA;
        WebProfileRegistry regB;
        QCOMPARE(regA.profileFor("t-shared-instances"), regB.profileFor("t-shared-instances"));
    }

    void profileFor_sharedAcrossSeparateQmlEngines() {
        // plasmashell runs one QQmlEngine per containment and qmltestrunner
        // starts a fresh engine per test file; the table has to survive
        // that, which a QML singleton (registered per-engine) would not.
        auto grabProfile = [](const QString& id) -> QObject* {
            QQmlEngine    engine;
            QQmlComponent component(&engine);
            component.setData(R"QML(
                import QtQuick
                import wekde.test 1.0
                QtObject {
                    property QtObject reg: WebProfileRegistry {}
                    property QtObject grabbed: null
                    function run(workshopId) { grabbed = reg.profileFor(workshopId); }
                }
            )QML",
                              QUrl());
            QScopedPointer<QObject> root(component.create());
            [&]() {
                QVERIFY2(root != nullptr, qPrintable(component.errorString()));
            }();
            QMetaObject::invokeMethod(root.data(), "run", Q_ARG(QVariant, id));
            return root->property("grabbed").value<QObject*>();
        };

        QObject* fromEngine1 = grabProfile("t-shared-engines");
        QObject* fromEngine2 = grabProfile("t-shared-engines");
        QVERIFY(fromEngine1 != nullptr);
        QCOMPARE(fromEngine1, fromEngine2);
    }

    void liveProfileCount_growsOnlyForNewNames() {
        WebProfileRegistry reg;
        const int          before = reg.liveProfileCount();
        reg.profileFor("t-count-first");
        QCOMPARE(reg.liveProfileCount(), before + 1);
        reg.profileFor("t-count-first"); // same name again
        QCOMPARE(reg.liveProfileCount(), before + 1);
        reg.profileFor("t-count-second");
        QCOMPARE(reg.liveProfileCount(), before + 2);
    }

    void interceptorFor_sameId_returnsSameInterceptor_withoutASecondProfile() {
        WebProfileRegistry reg;
        auto*              first  = reg.interceptorFor("t-icept-same");
        auto*              second = reg.interceptorFor("t-icept-same");
        QCOMPARE(first, second);
        assertInterceptorGatesFileScheme(first);
    }

    void interceptorFor_createsTheProfileItBelongsTo() {
        WebProfileRegistry reg;
        const int          before      = reg.liveProfileCount();
        auto*              interceptor = reg.interceptorFor("t-icept-creates-profile");
        QCOMPARE(reg.liveProfileCount(), before + 1);
        QVERIFY(qobject_cast<WebUrlInterceptor*>(interceptor) != nullptr);
        // Same name through profileFor() must not add a second profile.
        reg.profileFor("t-icept-creates-profile");
        QCOMPARE(reg.liveProfileCount(), before + 1);
    }

    void createdObjects_areCppOwnedAndParented() {
        WebProfileRegistry reg;
        auto*              profile     = reg.profileFor("t-ownership");
        auto*              interceptor = reg.interceptorFor("t-ownership");
        QCOMPARE(QQmlEngine::objectOwnership(profile), QQmlEngine::CppOwnership);
        QCOMPARE(QQmlEngine::objectOwnership(interceptor), QQmlEngine::CppOwnership);
        QVERIFY(profile->parent() != nullptr);
        QVERIFY(interceptor->parent() != nullptr);
    }

    // Everything QtWebView.qml calls on this class has to be reachable from
    // QML JS, not just legal C++ -- a plain public method compiles fine and
    // is invisible to QML's method dispatch (that exact gap took SafeWallpaper
    // Bridge's setters out of reach for months; see
    // tst_safewallpaperbridgecontroller.cpp). Drive it through a real
    // QQmlEngine so a method that quietly stops being Q_INVOKABLE fails here.
    void methodsAreReachableFromQml() {
        QQmlEngine    engine;
        QQmlComponent component(&engine);
        component.setData(R"QML(
            import QtQuick
            import wekde.test 1.0
            QtObject {
                id: root
                property QtObject reg: WebProfileRegistry {}
                property string storageName: ""
                property int    baseDirCalls: 0
                function driveFromJs() {
                    var profile = root.reg.profileFor("t-qml-reach");
                    root.storageName = profile.storageName;
                    var interceptor = root.reg.interceptorFor("t-qml-reach");
                    interceptor.setWallpaperBaseDir("/tmp/x");
                    root.baseDirCalls = root.reg.liveProfileCount();
                }
            }
        )QML",
                          QUrl());
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> root(component.create());
        QVERIFY(root != nullptr);
        QVERIFY(QMetaObject::invokeMethod(root.data(), "driveFromJs"));
        QCOMPARE(root->property("storageName").toString(), QStringLiteral("wek-wp-t-qml-reach"));
        QVERIFY(root->property("baseDirCalls").toInt() >= 1);
    }

    // The actual regression: two views on the SAME profile object (the
    // two-monitor case for one web wallpaper) both have to finish loading.
    // Before this class existed, two live QML WebEngineProfile objects on
    // one storageName silently stalled at LoadStartedStatus.
    //
    // The embedded QML uses "file:/tmp/" (one slash), not "file:///tmp/":
    // moc's comment stripper doesn't know about raw-string content, so a
    // "//" anywhere inside this R"QML(...)QML" block reads as a line
    // comment and eats the rest of the literal, silently producing an
    // empty .moc (moc reports "no relevant classes found" for the whole
    // file, not an error tied to this line).
    void sharedProfile_bothViewsLoadSuccessfully() {
        QQmlEngine    engine;
        QQmlComponent component(&engine);
        component.setData(R"QML(
            import QtQuick
            import QtWebEngine 1.10
            import wekde.test 1.0
            Item {
                id: root
                property QtObject reg: WebProfileRegistry {}
                property int status1: -1
                property int status2: -1
                WebEngineView {
                    id: view1
                    onLoadingChanged: (info) => { root.status1 = info.status }
                    Component.onCompleted: {
                        profile = root.reg.profileFor("t-two-monitor-view");
                        loadHtml("<html><body>view1 ok</body></html>", "file:/tmp/");
                    }
                }
                WebEngineView {
                    id: view2
                    onLoadingChanged: (info) => { root.status2 = info.status }
                    Component.onCompleted: {
                        profile = root.reg.profileFor("t-two-monitor-view");
                        loadHtml("<html><body>view2 ok</body></html>", "file:/tmp/");
                    }
                }
                function profileSame() { return view1.profile === view2.profile; }
            }
        )QML",
                          QUrl());
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> root(component.create());
        QVERIFY(root != nullptr);

        QVariant same;
        QMetaObject::invokeMethod(root.data(), "profileSame", Q_RETURN_ARG(QVariant, same));
        QVERIFY(same.toBool());

        const int LoadSucceededStatus = 2;
        QTRY_COMPARE_WITH_TIMEOUT(root->property("status1").toInt(), LoadSucceededStatus, 15000);
        QTRY_COMPARE_WITH_TIMEOUT(root->property("status2").toInt(), LoadSucceededStatus, 15000);
    }

    // Reproduces QtWebView.qml's real construction shape end to end:
    // workshopId supplied via createWithInitialProperties (never a default
    // binding -- QQmlComponent::create() evaluates default bindings during
    // beginCreate, before initial properties are applied), profile wired
    // through a Binding declared before the view so it applies at the
    // Binding's own componentComplete (which, in declaration order, runs
    // before the view's), and settings touched only from the view's
    // Component.onCompleted.
    //
    // homeContainsDefaultProfileDir() was the original plan for the
    // observable here (Qt substitutes its own global "Default" profile the
    // moment a WebEngineView initializes with nothing bound, and that
    // profile's directory is supposed to appear under the isolated HOME
    // right away). It doesn't: under this suite's offscreen /
    // --no-sandbox / --disable-gpu / no-D-Bus harness, NOTHING gets
    // written to disk for any profile within several seconds of a
    // successful load, including a real per-wallpaper one -- confirmed by
    // instrumenting sharedProfile_bothViewsLoadSuccessfully's profile
    // directory the same way. Chromium's disk cache / cookie / local-
    // storage directories are created lazily on first write, and a static
    // file: HTML page with no cookies or storage calls never triggers one
    // in this environment. So the directory check is kept as a best-effort
    // sanity call (still worth having if a future Qt build changes that),
    // but the load-bearing assertion is object identity at the exact
    // moment settings is touched, captured by the QML itself into
    // profileWhenSettingsTouched: reverting to reading `settings` from a
    // creation-time property binding (like the WebEngineView's old `_init`
    // property, before this fix) makes that recorder capture some OTHER,
    // already-live QQuickWebEngineProfile instead of the registry's real
    // one -- confirmed by running that broken shape here and reading the
    // two pointers back different, before switching to this fixed version.
    void constructionOrder_neverCreatesQtsDefaultProfile() {
        const QString home = QString::fromLocal8Bit(qgetenv("HOME"));
        QVERIFY(! home.isEmpty());
        QVERIFY(! homeContainsDefaultProfileDir(home));

        QQmlEngine    engine;
        QQmlComponent component(&engine);
        component.setData(R"QML(
            import QtQuick
            import QtWebEngine 1.10
            import wekde.test 1.0
            Item {
                id: root
                property QtObject reg: WebProfileRegistry {}
                property string workshopId: ""
                readonly property var wallpaperProfile:
                    workshopId ? reg.profileFor(workshopId) : null
                property var profileWhenSettingsTouched: undefined

                Binding {
                    target: view
                    property: "profile"
                    value: root.wallpaperProfile
                    when: root.wallpaperProfile !== null
                    restoreMode: Binding.RestoreNone
                }

                WebEngineView {
                    id: view
                    Component.onCompleted: {
                        root.profileWhenSettingsTouched = view.profile;
                        settings.localContentCanAccessRemoteUrls = true;
                        loadHtml("<html><body>ok</body></html>", "file:/tmp/");
                    }
                }
                function viewProfile() { return view.profile; }
            }
        )QML",
                          QUrl());
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));

        QVariantMap initial;
        initial.insert(QStringLiteral("workshopId"), QStringLiteral("t-construction-order"));
        QScopedPointer<QObject> root(component.createWithInitialProperties(initial));
        QVERIFY(root != nullptr);

        auto* reg = root->property("reg").value<QObject*>();
        QVERIFY(reg != nullptr);
        auto* expectedProfile = qobject_cast<WebProfileRegistry*>(reg)->profileFor(
            QStringLiteral("t-construction-order"));

        // The profile must already be the real one at the exact instant
        // settings gets touched -- not null, not some other object that a
        // later Binding write then papers over.
        QCOMPARE(root->property("profileWhenSettingsTouched").value<QObject*>(), expectedProfile);

        QVariant viewProfileVariant;
        QMetaObject::invokeMethod(
            root.data(), "viewProfile", Q_RETURN_ARG(QVariant, viewProfileVariant));
        QCOMPARE(viewProfileVariant.value<QObject*>(), expectedProfile);
    }
};

int main(int argc, char* argv[]) {
    QtWebEngineQuick::initialize();
    QGuiApplication        app(argc, argv);
    TestWebProfileRegistry tc;
    return QTest::qExec(&tc, argc, argv);
}
#include "tst_webprofileregistry.moc"
