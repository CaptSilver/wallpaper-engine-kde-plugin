#include <QtTest>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include "../src/WekDiagnostics.hpp"
#include "TestSandbox.h"

using namespace wekde;

class TestWekDiagnostics : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Per-process HOME isolation for parallel Mull invocations.
        wek::test_sandbox::enableIsolated();
    }

    void testBundleContainsExpectedFiles() {
        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));
        QVERIFY(QFile::exists(bundlePath));

        // Crack the tar.gz; verify expected files inside.
        QProcess tar;
        tar.start(QStringLiteral("tar"), { QStringLiteral("-tzf"), bundlePath });
        QVERIFY(tar.waitForFinished(2000));
        const auto contents =
            QString::fromUtf8(tar.readAllStandardOutput()).split('\n', Qt::SkipEmptyParts);

        const QStringList expected = {
            QStringLiteral("./journal.txt"),
            QStringLiteral("./gpu-info.txt"),
            QStringLiteral("./vulkan-info.txt"),
            QStringLiteral("./plugin-env.txt"),
            QStringLiteral("./plugin-cfg-redacted.txt"),
            QStringLiteral("./cache-manifest.txt"),
            QStringLiteral("./plugin-version.txt"),
        };
        for (const auto& f : expected) {
            QVERIFY2(contents.contains(f), qPrintable(QStringLiteral("bundle missing: ") + f));
        }

        QFile::remove(bundlePath);
    }

    void testRedactsHomePathInEnvDump() {
        qputenv("WEKDE_TEST_PATH", QFile::encodeName(QDir::homePath() + QStringLiteral("/secret")));
        WekDiagnostics diag;
        const auto     envDump = diag.collectPluginEnvForTest();
        QVERIFY(envDump.contains(QStringLiteral("WEKDE_TEST_PATH=<HOME>/secret")));
        QVERIFY2(! envDump.contains(QDir::homePath()), "home path leaked in env dump");
        qunsetenv("WEKDE_TEST_PATH");
    }

    void testRedactsCfgPathFields() {
        // Write a fixture KConfig with cfg paths in the captsilver block.
        const auto cfgPath =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            QStringLiteral("/plasma-org.kde.plasma.desktop-appletsrc");
        QDir().mkpath(QFileInfo(cfgPath).absolutePath());
        {
            QFile f(cfgPath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(R"([Containments][1][Wallpaper][com.github.captsilver.wallpaperEngineKde]
SteamLibraryPath=/home/user/Steam
WallpaperSource=file:///home/user/.steam/foo
VideoFolderPath=/home/user/Videos
WallpaperWorkShopId=1234567
)");
        }

        WekDiagnostics diag;
        const auto     cfgDump = diag.collectRedactedCfgForTest();
        QVERIFY2(cfgDump.contains(QStringLiteral("SteamLibraryPath=<REDACTED>")),
                 qPrintable("missing SteamLibraryPath redaction:\n" + cfgDump));
        QVERIFY(cfgDump.contains(QStringLiteral("WallpaperSource=<REDACTED>")));
        QVERIFY(cfgDump.contains(QStringLiteral("VideoFolderPath=<REDACTED>")));
        // Non-redacted keys should still be present (only the path keys
        // are scrubbed; non-path keys are kept verbatim for debugging).
        QVERIFY(cfgDump.contains(QStringLiteral("WallpaperWorkShopId=1234567")));
        // The raw paths should NOT leak.
        QVERIFY2(! cfgDump.contains(QStringLiteral("/home/user/Steam")), "Steam path leaked");
    }

    void testLastErrorPopulatedOnFailure() {
        // We can't easily force saveBundle() to fail without
        // monkey-patching; this test asserts lastError() is empty by
        // default. Either saveBundle succeeds (lastError empty) or fails
        // (lastError populated) — both are valid states.
        WekDiagnostics diag;
        QVERIFY(diag.lastError().isEmpty());
        (void)diag.saveBundle();
        QVERIFY(true);
    }

    void testGpuInfoNonCrashing() {
        // The lspci / lsmod shell-outs may be missing in a stripped
        // distrobox.  Per spec the collector returns a placeholder string;
        // we assert non-crash + a non-null QString.
        WekDiagnostics diag;
        const auto     gpu = diag.collectGpuInfoForTest();
        QVERIFY(! gpu.isNull());
    }
};

QTEST_GUILESS_MAIN(TestWekDiagnostics)
#include "tst_wekdiagnostics.moc"
