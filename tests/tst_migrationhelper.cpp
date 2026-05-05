#include <QtTest>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <QElapsedTimer>

#include "MigrationHelper.h"

class TstMigrationHelper : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        // Don't use setTestModeEnabled — it overrides GenericConfigLocation
        // to ~/.qttest/config and ignores XDG_CONFIG_HOME, which we rely on
        // to point the helper at our QTemporaryDir.
    }

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

    void runIfNeededInvokesScript() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1]\n"
                "wallpaperplugin=com.github.catsout.wallpaperEngineKde\n");
        a.close();

        const QString stub_dir = d.path() + "/bin";
        QDir().mkpath(stub_dir);
        const QString stub = stub_dir + "/wek-migrate-from-catsout";
        QFile s(stub);
        QVERIFY(s.open(QIODevice::WriteOnly));
        s.write("#!/usr/bin/env bash\ntouch \"" + d.path().toUtf8()
                + "/script-was-called\"\n");
        s.close();
        QFile::setPermissions(stub,
            QFileDevice::ReadOwner | QFileDevice::WriteOwner |
            QFileDevice::ExeOwner | QFileDevice::ReadGroup |
            QFileDevice::ExeGroup | QFileDevice::ReadOther |
            QFileDevice::ExeOther);

        const QByteArray oldPath = qgetenv("PATH");
        qputenv("PATH", (stub_dir + ":" + oldPath).toLocal8Bit());

        wekde::MigrationHelper helper;
        helper.runIfNeeded();

        const QString sentinel = d.path() + "/script-was-called";
        QElapsedTimer t; t.start();
        while (t.elapsed() < 2000 && ! QFile::exists(sentinel)) {
            QTest::qWait(50);
        }
        QVERIFY2(QFile::exists(sentinel),
                 "wek-migrate-from-catsout was not invoked within 2s");

        qputenv("PATH", oldPath);
    }

    void runIfNeededNoOpWhenScriptMissing() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());

        QFile a(d.path() + "/plasma-org.kde.plasma.desktop-appletsrc");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("[Containments][1]\n"
                "wallpaperplugin=com.github.catsout.wallpaperEngineKde\n");
        a.close();

        const QString empty_dir = d.path() + "/empty";
        QDir().mkpath(empty_dir);
        const QByteArray oldPath = qgetenv("PATH");
        qputenv("PATH", empty_dir.toLocal8Bit());

        wekde::MigrationHelper helper;
        helper.runIfNeeded();  // Should not throw, hang, or crash.

        qputenv("PATH", oldPath);
    }
};

QTEST_GUILESS_MAIN(TstMigrationHelper)
#include "tst_migrationhelper.moc"
