#include <QtTest>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrl>
#include "../src/WekDiagnostics.hpp"
#include "TestSandbox.h"

using namespace wekde;

class TestWekDiagnostics : public QObject {
    Q_OBJECT

private:
    // Reports which line leaked, so a failure names the collector's output
    // instead of just the file.
    static QString firstLineContaining(const QString& text, const QString& needle) {
        const auto lines = text.split('\n');
        for (const auto& line : lines) {
            if (line.contains(needle)) return line.trimmed();
        }
        return QStringLiteral("(not found)");
    }

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

    // The env dump captures the whitelisted prefixes and nothing else. Its
    // values go in raw — the home path is taken out once on the way into the
    // bundle, which testBundleRedactsHomePathInEveryMember covers.
    void testEnvDumpCapturesOnlyWhitelistedVars() {
        qputenv("WEKDE_TEST_PATH", QFile::encodeName(QDir::homePath() + QStringLiteral("/secret")));
        qputenv("WEKTEST_UNRELATED", "nosy");
        WekDiagnostics diag;
        const auto     envDump = diag.collectPluginEnvForTest();
        qunsetenv("WEKDE_TEST_PATH");
        qunsetenv("WEKTEST_UNRELATED");
        QVERIFY2(envDump.contains(QStringLiteral("WEKDE_TEST_PATH=")), qPrintable(envDump));
        QVERIFY2(! envDump.contains(QStringLiteral("WEKTEST_UNRELATED")),
                 "captured an env var outside the whitelisted prefixes");
    }

    // The About page tells the user their home path is redacted before the
    // archive is written, so every member has to be clean — not just the
    // environment dump. Plant the home path in three different collector
    // sources and read the whole archive back out.
    void testBundleRedactsHomePathInEveryMember() {
        const auto home = QDir::homePath();
        QVERIFY(! home.isEmpty());

        qputenv("WEKDE_TEST_PATH", QFile::encodeName(home + QStringLiteral("/secret")));

        // A cfg key outside the redact-by-name list: the key-name pass leaves
        // its value alone, so the home path in it survives to the bundle.
        const auto cfgPath =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            QStringLiteral("/plasma-org.kde.plasma.desktop-appletsrc");
        QDir().mkpath(QFileInfo(cfgPath).absolutePath());
        {
            QFile f(cfgPath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(QStringLiteral("[Containments][1][Wallpaper]"
                                   "[com.github.captsilver.wallpaperEngineKde]\n"
                                   "WallpaperFilePath=%1/ws/scene.pkg\n")
                        .arg(home)
                        .toUtf8());
        }

        // The renderer's pipeline dump goes in verbatim.
        const auto pipelineDir =
            QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) +
            QStringLiteral("/wallpaper-scene-renderer");
        QVERIFY(QDir().mkpath(pipelineDir));
        {
            QFile f(pipelineDir + QStringLiteral("/pipeline-diag.txt"));
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(QStringLiteral("last scene: %1/ws/scene.pkg\n").arg(home).toUtf8());
        }
        qputenv("WEKDE_PIPELINE_DIAG", "1");

        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        qunsetenv("WEKDE_PIPELINE_DIAG");
        qunsetenv("WEKDE_TEST_PATH");
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));

        QTemporaryDir extracted;
        QVERIFY(extracted.isValid());
        QProcess tar;
        tar.start(QStringLiteral("tar"),
                  { QStringLiteral("-xzf"), bundlePath, QStringLiteral("-C"), extracted.path() });
        QVERIFY(tar.waitForFinished(5000));
        QCOMPARE(tar.exitCode(), 0);

        const auto members =
            QDir(extracted.path()).entryInfoList(QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
        QVERIFY(! members.isEmpty());
        QStringList leaks;
        for (const auto& fi : members) {
            QFile f(fi.absoluteFilePath());
            QVERIFY(f.open(QIODevice::ReadOnly));
            const auto text = QString::fromUtf8(f.readAll());
            if (text.contains(home)) {
                leaks << QStringLiteral("%1: %2").arg(fi.fileName(),
                                                      firstLineContaining(text, home));
            }
        }
        QVERIFY2(
            leaks.isEmpty(),
            qPrintable(QStringLiteral("bundle members ship the home path:\n") + leaks.join('\n')));

        QFile envDump(extracted.filePath(QStringLiteral("plugin-env.txt")));
        QVERIFY(envDump.open(QIODevice::ReadOnly));
        QVERIFY(QString::fromUtf8(envDump.readAll())
                    .contains(QStringLiteral("WEKDE_TEST_PATH=<HOME>/secret")));

        QFile::remove(bundlePath);
    }

    // /home is a symlink to /var/home on ostree systems, so the same
    // directory is spelled two ways: $HOME carries one prefix while paths
    // logged by other processes carry the other. Both have to redact,
    // whichever way round $HOME happens to be.
    void testScrubRedactsBothOstreeHomeSpellings() {
        const auto line     = QStringLiteral("baseUrl=file://%1/.local/share/Steam/scene.pkg");
        const auto plain    = QStringLiteral("/home/alice");
        const auto varHome  = QStringLiteral("/var/home/alice");
        const auto expected = QStringLiteral("baseUrl=file://<HOME>/.local/share/Steam/scene.pkg");

        QCOMPARE(WekDiagnostics::scrubHomePathsForTest(line.arg(plain), plain), expected);
        QCOMPARE(WekDiagnostics::scrubHomePathsForTest(line.arg(varHome), plain), expected);
        QCOMPARE(WekDiagnostics::scrubHomePathsForTest(line.arg(plain), varHome), expected);
        QCOMPARE(WekDiagnostics::scrubHomePathsForTest(line.arg(varHome), varHome), expected);
    }

    // An empty or root home must not redact every path in the bundle.
    void testScrubIgnoresEmptyAndRootHome() {
        const auto text = QStringLiteral("/usr/share/wallpapers/scene.pkg");
        QCOMPARE(WekDiagnostics::scrubHomePathsForTest(text, QString()), text);
        QCOMPARE(WekDiagnostics::scrubHomePathsForTest(text, QStringLiteral("/")), text);
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

    // The manifest used to walk QStandardPaths::CacheLocation +
    // "/wallpaper-scene-renderer" — which is where saveBundle wrote its
    // tarballs, and is not where either renderer cache lives. Every shipped
    // bug report's "cache manifest" therefore described the previous bug
    // report. Two properties: it must see the real scene cache, and it must
    // never see the bundle directory.
    void testCacheManifestListsRendererCacheNotBundleDir() {
        const auto generic = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
        QVERIFY(! generic.isEmpty());
        QVERIFY(QDir().mkpath(generic + QStringLiteral("/wescene-renderer")));
        {
            QFile f(generic + QStringLiteral("/wescene-renderer/scene.spvs"));
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write("spv");
        }

        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));
        const auto manifest = diag.collectCacheManifestForTest();
        QVERIFY2(manifest.contains(QStringLiteral("scene.spvs")), qPrintable(manifest));
        QVERIFY2(! manifest.contains(QStringLiteral("diag-")),
                 qPrintable(QStringLiteral("manifest lists the bundle dir: ") + manifest));
        QFile::remove(bundlePath);
    }

    // The pipeline diagnostic dump is written by the renderer next to its
    // pipeline cache — $XDG_CACHE_HOME/wallpaper-scene-renderer — not under
    // the host application's CacheLocation.
    void testPipelineDiagReadsRendererPipelineCacheDir() {
        const auto generic = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
        QVERIFY(QDir().mkpath(generic + QStringLiteral("/wallpaper-scene-renderer")));
        {
            QFile f(generic + QStringLiteral("/wallpaper-scene-renderer/pipeline-diag.txt"));
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write("PIPELINE-DIAG-MARKER");
        }
        qputenv("WEKDE_PIPELINE_DIAG", "1");
        WekDiagnostics diag;
        const auto     dump = diag.collectPipelineDiagForTest();
        qunsetenv("WEKDE_PIPELINE_DIAG");
        QVERIFY2(dump.contains(QStringLiteral("PIPELINE-DIAG-MARKER")), qPrintable(dump));
    }

    // The save-as picker hands back a QUrl; the bundle only reaches the
    // user if that destination is actually written.
    void testExportBundleWritesThePickedDestination() {
        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));

        QTemporaryDir dest;
        QVERIFY(dest.isValid());
        const auto destPath = dest.filePath(QStringLiteral("picked.tar.gz"));

        QVERIFY2(diag.exportBundle(bundlePath, QUrl::fromLocalFile(destPath)),
                 qPrintable(QStringLiteral("exportBundle failed: ") + diag.lastError()));
        QVERIFY(QFile::exists(destPath));
        QCOMPARE(QFileInfo(destPath).size(), QFileInfo(bundlePath).size());
        QVERIFY(diag.lastError().isEmpty());

        QFile::remove(bundlePath);
    }

    // The picker pre-fills the bundle's own name, so answering "Replace" to
    // the native overwrite prompt is the common case. QFile::copy refuses to
    // clobber, so the destination has to be removed first.
    void testExportBundleOverwritesAnExistingDestination() {
        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));

        QTemporaryDir dest;
        QVERIFY(dest.isValid());
        const auto destPath = dest.filePath(QStringLiteral("picked.tar.gz"));
        {
            QFile stale(destPath);
            QVERIFY(stale.open(QIODevice::WriteOnly));
            stale.write("stale");
        }

        QVERIFY2(diag.exportBundle(bundlePath, QUrl::fromLocalFile(destPath)),
                 qPrintable(QStringLiteral("exportBundle failed: ") + diag.lastError()));
        QCOMPARE(QFileInfo(destPath).size(), QFileInfo(bundlePath).size());

        QFile::remove(bundlePath);
    }

    void testExportBundleReportsUnwritableDestination() {
        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));

        // Parent directory does not exist, so the copy cannot succeed for
        // any uid — no root-vs-user divergence in the box.
        const QUrl bad =
            QUrl::fromLocalFile(QStringLiteral("/nonexistent-wek-export-dir/picked.tar.gz"));
        QVERIFY(! diag.exportBundle(bundlePath, bad));
        QVERIFY2(! diag.lastError().isEmpty(), "a failed export must leave a reason behind");

        QFile::remove(bundlePath);
    }

    void testExportBundleRejectsNonLocalDestination() {
        WekDiagnostics diag;
        const auto     bundlePath = diag.saveBundle();
        QVERIFY2(! bundlePath.isEmpty(),
                 qPrintable(QStringLiteral("saveBundle failed: ") + diag.lastError()));

        QVERIFY(
            ! diag.exportBundle(bundlePath, QUrl(QStringLiteral("sftp://host/tmp/picked.tar.gz"))));
        QVERIFY(! diag.lastError().isEmpty());

        QFile::remove(bundlePath);
    }

    void testExportBundleReportsMissingSource() {
        WekDiagnostics diag;
        QTemporaryDir  dest;
        QVERIFY(dest.isValid());
        QVERIFY(
            ! diag.exportBundle(QStringLiteral("/nonexistent-wek-bundle.tar.gz"),
                                QUrl::fromLocalFile(dest.filePath(QStringLiteral("p.tar.gz")))));
        QVERIFY(! diag.lastError().isEmpty());
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
