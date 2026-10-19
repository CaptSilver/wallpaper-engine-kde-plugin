#include <QtQuickTest/quicktest.h>

#include "../QmlTestStubs.h"
#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QString>
#include <KLocalizedContext>

#include "FakeWallpaper.h"
#include "../TestSandbox.h"

// QuickTest setup: inject `wallpaper` as a context property backed by real C++
// objects, reusing the existing tests/qml/_stubs. main.qml then loads exactly as
// in production (wallpaper is a context property, configuration is a real QObject
// whose per-key NOTIFY signals drive main.qml's reactive Connections).
class Setup : public QObject {
    Q_OBJECT
    QmlTestStubs stubs;
public slots:
    void applicationAvailable() { wek::test_sandbox::enableIsolated(); }

    void qmlEngineAvailable(QQmlEngine* engine) {
        engine->addUrlInterceptor(&stubs);
        const QString repo = QStringLiteral(WEKDE_REPO_DIR);
        engine->addImportPath(repo + "/tests/qml/_stubs");
        engine->addImportPath(repo + "/tests/qml");

        QT_WARNING_PUSH
        QT_WARNING_DISABLE_DEPRECATED
        engine->rootContext()->setContextObject(new KLocalizedContext(engine));
        QT_WARNING_POP

        auto* wallpaper = buildOwnedFakeWallpaperTree(engine);

        // Test-friendly overrides differing from main.xml defaults.
        wallpaper->config()->setProperty("MouseInput", false); // avoid 2s hookTimer tree-dump

        engine->rootContext()->setContextProperty(QStringLiteral("wallpaper"), wallpaper);
    }
};

QUICK_TEST_MAIN_WITH_SETUP(main_integration, Setup)
#include "main.moc"
