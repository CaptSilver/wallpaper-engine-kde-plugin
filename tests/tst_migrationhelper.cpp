#include <QtTest>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <QFile>
#include <QFileInfo>
#include <QDir>

#include <KConfig>
#include <KConfigGroup>

#include "MigrationHelper.h"

class TstMigrationHelper : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        // Don't use setTestModeEnabled — it overrides GenericConfigLocation
        // to ~/.qttest/config and ignores XDG_CONFIG_HOME, which we rely on
        // to point the helper at our QTemporaryDir.
    }

    // ── shouldRun() ───────────────────────────────────────────────────────────
    void noWorkWhenMarkerPresent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QDir(d.path()).mkpath("wekde");
        QFile m(d.path() + "/wekde/migrated-from-catsout");
        QVERIFY(m.open(QIODevice::WriteOnly));
        m.write("ok\n");
        m.close();

        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1]\n"
                "wallpaperplugin=com.github.catsout.wallpaperEngineKde\n");
        a.close();

        wekde::MigrationHelper helper;
        QCOMPARE(helper.shouldRun(), false);
    }

    void noWorkWhenAppletsrcAbsent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());
        wekde::MigrationHelper helper;
        QCOMPARE(helper.shouldRun(), false);
    }

    void noWorkWhenAppletsrcLacksCatsout() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());
        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1]\n"
                "wallpaperplugin=com.github.captsilver.wallpaperEngineKde\n");
        a.close();
        wekde::MigrationHelper helper;
        QCOMPARE(helper.shouldRun(), false);
    }

    void shouldRunWhenCatsoutSelectorPresent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());
        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1]\n"
                "wallpaperplugin=com.github.catsout.wallpaperEngineKde\n");
        a.close();
        wekde::MigrationHelper helper;
        QCOMPARE(helper.shouldRun(), true);
    }

    void shouldRunWhenCatsoutSectionPresent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());
        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Backend=2\n");
        a.close();
        wekde::MigrationHelper helper;
        QCOMPARE(helper.shouldRun(), true);
    }

    // ── runIfNeeded(): in-process KConfig merge ───────────────────────────────
    void runIfNeededWritesMarker() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n");
        a.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        QVERIFY(QFile::exists(d.path() + "/wekde/migrated-from-catsout"));
        // shouldRun returns false now that marker exists
        QCOMPARE(helper.shouldRun(), false);
    }

    void runIfNeededMergesKeysIntoCaptsilver() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        const QString p = d.path() + "/plasma-org.kde.plasma.desktop-appletsrc";
        QFile         a(p);
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][38][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n"
                "Fps=60\n"
                "MuteAudio=false\n"
                "\n"
                "[Containments][38][Wallpaper][com.github.captsilver.wallpaperEngineKde][General]\n"
                "WallpaperWorkShopId=2800255344\n");
        a.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        // Verify captsilver section now has the merged keys.
        KConfig      config(p, KConfig::SimpleConfig);
        KConfigGroup cs = config.group(QStringLiteral("Containments"))
                              .group(QStringLiteral("38"))
                              .group(QStringLiteral("Wallpaper"))
                              .group(QStringLiteral("com.github.captsilver.wallpaperEngineKde"))
                              .group(QStringLiteral("General"));
        QCOMPARE(cs.readEntry("Volume", QString()), QString("42"));
        QCOMPARE(cs.readEntry("Fps", QString()), QString("60"));
        QCOMPARE(cs.readEntry("MuteAudio", QString()), QString("false"));
        // Original captsilver value preserved.
        QCOMPARE(cs.readEntry("WallpaperWorkShopId", QString()), QString("2800255344"));
    }

    void runIfNeededDoesNotOverwriteExistingCaptsilverKeys() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        const QString p = d.path() + "/plasma-org.kde.plasma.desktop-appletsrc";
        QFile         a(p);
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n"
                "\n"
                "[Containments][1][Wallpaper][com.github.captsilver.wallpaperEngineKde][General]\n"
                "Volume=99\n"); // captsilver already has Volume — should win
        a.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        KConfig      config(p, KConfig::SimpleConfig);
        KConfigGroup cs = config.group(QStringLiteral("Containments"))
                              .group(QStringLiteral("1"))
                              .group(QStringLiteral("Wallpaper"))
                              .group(QStringLiteral("com.github.captsilver.wallpaperEngineKde"))
                              .group(QStringLiteral("General"));
        QCOMPARE(cs.readEntry("Volume", QString()), QString("99"));
    }

    void runIfNeededIdempotent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        const QString p = d.path() + "/plasma-org.kde.plasma.desktop-appletsrc";
        QFile         a(p);
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n");
        a.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();
        // Second call is a no-op (marker present, shouldRun returns false).
        const auto sizeAfterFirst = QFileInfo(p).size();
        helper.runIfNeeded();
        QCOMPARE(QFileInfo(p).size(), sizeAfterFirst);
    }

    // Item 20: the Doxygen promises a per-KEY idempotent merge: a second
    // runIfNeeded() (even with the marker deleted, fresh instance) must not
    // overwrite a value the user changed in the captsilver section after the
    // first migration (the hasKey guard).
    void runIfNeeded_idempotent_secondRunCopiesNothingNew() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        const QString p = d.path() + "/plasma-org.kde.plasma.desktop-appletsrc";
        QFile         a(p);
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n");
        a.close();

        // First migration: copies Volume=42 into the captsilver section.
        wekde::MigrationHelper helper1;
        helper1.runIfNeeded();

        auto captsilverVolume = [&]() {
            KConfig cfg(p, KConfig::SimpleConfig);
            return cfg.group(QStringLiteral("Containments"))
                .group(QStringLiteral("1"))
                .group(QStringLiteral("Wallpaper"))
                .group(QStringLiteral("com.github.captsilver.wallpaperEngineKde"))
                .group(QStringLiteral("General"))
                .readEntry("Volume", QString());
        };
        QCOMPARE(captsilverVolume(), QString("42"));

        // User changes the captsilver value post-migration.
        {
            KConfig cfg(p, KConfig::SimpleConfig);
            cfg.group(QStringLiteral("Containments"))
                .group(QStringLiteral("1"))
                .group(QStringLiteral("Wallpaper"))
                .group(QStringLiteral("com.github.captsilver.wallpaperEngineKde"))
                .group(QStringLiteral("General"))
                .writeEntry("Volume", QString("7"));
            cfg.sync();
        }

        // Delete the marker so shouldRun() is true again, then re-run with a
        // FRESH helper instance (so the per-instance guard doesn't suppress it).
        QFile::remove(d.path() + "/wekde/migrated-from-catsout");
        wekde::MigrationHelper helper2;
        helper2.runIfNeeded();

        // The user's edit (7) must survive — the catsout 42 must NOT overwrite it.
        QCOMPARE(captsilverVolume(), QString("7"));
    }

    // The per-instance guard: a single helper that already attempted migration
    // must no-op on a second runIfNeeded() WITHIN ITS LIFETIME, even if the
    // marker is deleted (the false "flock" claim was gesturing at this in-process
    // case). A fresh instance is unaffected (covered by the idempotency test).
    void runIfNeeded_secondRunWithinInstance_isNoop() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        const QString p = d.path() + "/plasma-org.kde.plasma.desktop-appletsrc";
        QFile         a(p);
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n");
        a.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();
        const QString markerPath = d.path() + "/wekde/migrated-from-catsout";
        QVERIFY(QFile::exists(markerPath));

        // Delete the marker; a guardless impl would re-merge + rewrite it. The
        // SAME instance must skip because it already attempted.
        QFile::remove(markerPath);
        helper.runIfNeeded();
        // No-op: the marker was NOT rewritten by this instance.
        QVERIFY(! QFile::exists(markerPath));
    }

    void runIfNeededNoOpWhenAlreadyMigrated() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QDir(d.path()).mkpath("wekde");
        QFile m(d.path() + "/wekde/migrated-from-catsout");
        QVERIFY(m.open(QIODevice::WriteOnly));
        m.write("ok\n");
        m.close();

        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "Volume=42\n");
        a.close();
        const auto sizeBefore = QFileInfo(a.fileName()).size();

        wekde::MigrationHelper helper;
        helper.runIfNeeded(); // no-op
        QCOMPARE(QFileInfo(a.fileName()).size(), sizeBefore);
    }

    // ── kscreenlockerrc (lockscreen wallpaper config) coverage ────────────────
    // The shell shim's two-file iteration (scripts/migrate-from-catsout.sh:137,161)
    // includes "$CONFIG_HOME/kscreenlockerrc" alongside the appletsrc glob; the
    // in-process port previously only walked appletsrc, leaving users whose
    // lockscreen wallpaper was set to the catsout build with a permanently
    // broken lockscreen wallpaper after the rename.

    // The headline scenario: catsout appears ONLY in kscreenlockerrc; appletsrc
    // is absent (or has no catsout reference). shouldRun() must return true so
    // the helper picks up the lockscreen migration.
    void shouldRun_kscreenlockerrcMentionsCatsout_returnsTrue() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        // No appletsrc; only kscreenlockerrc with catsout.
        QFile k(d.path() + "/kscreenlockerrc");
        QVERIFY(k.open(QIODevice::WriteOnly | QIODevice::Text));
        k.write("[Greeter][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/lockscreen.mp4\n");
        k.close();

        wekde::MigrationHelper helper;
        QCOMPARE(helper.shouldRun(), true);
    }

    // The full migration: both files have catsout subtrees; helper must rewrite
    // the kscreenlockerrc captsilver subtree with the merged keys.
    void runIfNeeded_kscreenlockerrcRewrittenInPlace() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly | QIODevice::Text));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/desktop.mp4\n");
        a.close();
        QFile k(d.path() + "/kscreenlockerrc");
        QVERIFY(k.open(QIODevice::WriteOnly | QIODevice::Text));
        k.write("[Greeter][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/lockscreen.mp4\n");
        k.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        // Re-open kscreenlockerrc, verify the captsilver subtree exists with
        // the merged key.
        KConfig      locker(d.path() + "/kscreenlockerrc", KConfig::SimpleConfig);
        KConfigGroup captsilverG =
            locker.group(QStringLiteral("Greeter"))
                .group(QStringLiteral("Wallpaper"))
                .group(QStringLiteral("com.github.captsilver.wallpaperEngineKde"))
                .group(QStringLiteral("General"));
        QVERIFY(captsilverG.exists());
        QCOMPARE(captsilverG.readEntry("WallpaperSource", QString()),
                 QStringLiteral("/tmp/lockscreen.mp4"));
    }

    // Pre-rename user edit (captsilver subtree already has WallpaperSource) is
    // preserved — mirror of the existing appletsrc test at the [Greeter] root.
    void runIfNeeded_kscreenlockerrcDoesNotOverwriteExistingCaptsilverKeys() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QFile k(d.path() + "/kscreenlockerrc");
        QVERIFY(k.open(QIODevice::WriteOnly | QIODevice::Text));
        k.write("[Greeter][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/old.mp4\n"
                "\n"
                "[Greeter][Wallpaper][com.github.captsilver.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/new.mp4\n");
        k.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        KConfig      locker(d.path() + "/kscreenlockerrc", KConfig::SimpleConfig);
        KConfigGroup captsilverG =
            locker.group(QStringLiteral("Greeter"))
                .group(QStringLiteral("Wallpaper"))
                .group(QStringLiteral("com.github.captsilver.wallpaperEngineKde"))
                .group(QStringLiteral("General"));
        // User's post-rename value (/tmp/new.mp4) survives the merge.
        QCOMPARE(captsilverG.readEntry("WallpaperSource", QString()),
                 QStringLiteral("/tmp/new.mp4"));
    }

    // No kscreenlockerrc on disk → no crash, no stub file created. (Users who
    // never set a lockscreen wallpaper don't get an empty config file
    // manufactured by the migration.)
    void runIfNeeded_kscreenlockerrcAbsent_noCrashNoStubCreated() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        // Only appletsrc with catsout; no kscreenlockerrc.
        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly | QIODevice::Text));
        a.write("[Containments][1][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/desktop.mp4\n");
        a.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        QVERIFY(! QFileInfo::exists(d.path() + "/kscreenlockerrc"));
    }

    // Marker is written even when ONLY kscreenlockerrc contributed work (i.e.
    // appletsrc was absent / had no catsout). The marker prevents re-fire on
    // the next plasma start.
    void runIfNeeded_writesMarkerEvenIfOnlyKscreenlockerrcHadWork() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        // No appletsrc, only kscreenlockerrc with catsout.
        QFile k(d.path() + "/kscreenlockerrc");
        QVERIFY(k.open(QIODevice::WriteOnly | QIODevice::Text));
        k.write("[Greeter][Wallpaper][com.github.catsout.wallpaperEngineKde][General]\n"
                "WallpaperSource=/tmp/lockscreen.mp4\n");
        k.close();

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        QVERIFY(QFileInfo::exists(d.path() + "/wekde/migrated-from-catsout"));
    }
};

QTEST_GUILESS_MAIN(TstMigrationHelper)
#include "tst_migrationhelper.moc"
