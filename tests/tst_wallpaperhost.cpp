#include <QtTest>

#include "WallpaperHost.hpp"

// The global shortcuts drive the wallpaper running in plasmashell over D-Bus.
// System Settings and kcmshell load the plugin for its settings page too; they
// must not register the shortcut component a second time.
class TestWallpaperHost : public QObject {
    Q_OBJECT
private slots:
    void onlyPlasmashellHostsWallpapers() {
        QVERIFY(wekde::HostsWallpapers(QStringLiteral("plasmashell")));
        QVERIFY(! wekde::HostsWallpapers(QStringLiteral("systemsettings")));
        QVERIFY(! wekde::HostsWallpapers(QStringLiteral("kcmshell6")));
        QVERIFY(! wekde::HostsWallpapers(QStringLiteral("qml")));
        QVERIFY(! wekde::HostsWallpapers(QString()));
    }
};

QTEST_GUILESS_MAIN(TestWallpaperHost)
#include "tst_wallpaperhost.moc"
