#include <QtQuickTest/quicktest.h>

#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QString>

#include "FakeWallpaper.h"

// QuickTest setup: inject `wallpaper` as a context property backed by real C++
// objects, reusing the existing tests/qml/_stubs. main.qml then loads exactly as
// in production (wallpaper is a context property, configuration is a real QObject
// whose per-key NOTIFY signals drive main.qml's reactive Connections).
class Setup : public QObject {
    Q_OBJECT
public slots:
    void qmlEngineAvailable(QQmlEngine* engine) {
        const QString repo = QStringLiteral(WEKDE_REPO_DIR);
        engine->addImportPath(repo + "/tests/qml/_stubs");
        engine->addImportPath(repo + "/tests/qml");

        auto* containment = new FakeContainment();
        auto* wallpaper   = new FakeWallpaperItem();
        wallpaper->setParentItem(containment); // wallpaper.parent -> containment

        // Test-friendly overrides differing from main.xml defaults.
        wallpaper->config()->setProperty("MouseInput", false); // avoid 2s hookTimer tree-dump

        engine->rootContext()->setContextProperty(QStringLiteral("wallpaper"), wallpaper);
    }
};

QUICK_TEST_MAIN_WITH_SETUP(main_integration, Setup)
#include "main.moc"
