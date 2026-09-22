// QML test entry point used in place of the stock qmltestrunner binary.
//
// Plasma never gets i18n()/i18nc()/i18np()/i18ncp() into a wallpaper's QML by
// having that file import org.kde.plasma.core -- plasmashell installs a
// localized context on each engine's root context once (PlasmaCore's own
// corebindingsplugin does the same, via KLocalizedQmlContext since it
// replaced the deprecated KLocalizedContext in KF 6.8), and every file
// loaded through that engine inherits the globals from there. The stock
// qmltestrunner has no such setup step, so it only produced working
// i18n*() calls here because some test file's org.kde.plasma.core import
// happened to trigger the same context object as an unrelated load-time
// side effect. Deleting those dead imports (elsewhere in this tree) removed
// that accident, not a real dependency -- so the fix belongs in the
// harness, matching how production actually gets its bindings, not in
// restoring an import nothing else uses.
#include <KLocalizedContext>
#include <QQmlContext>
#include <QQmlEngine>
#include <QtQuickTest/quicktest.h>

class I18nQuickTestSetup : public QObject {
    Q_OBJECT

public slots:
    void qmlEngineAvailable(QQmlEngine* engine) {
        // Production (corebindingsplugin.so) installs KLocalizedQmlContext,
        // not this class -- KLocalizedContext has been deprecated in its
        // favour since KF 6.8. We still use the deprecated one here: it
        // lives in KF6::I18n, already linked by every other test in this
        // tree and available since KF 5.17, while KLocalizedQmlContext
        // lives in the separate KF6::I18nQml target that this project's
        // supported-distro floor hasn't been checked against. Both classes
        // install the same i18n()/i18nc()/i18np()/i18ncp() context globals,
        // which is all a test harness needs -- so silence the deprecation
        // warning rather than take on a new link dependency for a class
        // whose only difference here is which QML type system integration
        // it additionally offers.
        QT_WARNING_PUSH
        QT_WARNING_DISABLE_DEPRECATED
        engine->rootContext()->setContextObject(new KLocalizedContext(engine));
        QT_WARNING_POP
    }
};

QUICK_TEST_MAIN_WITH_SETUP(tst_qml, I18nQuickTestSetup)

#include "qml_test_runner.moc"
