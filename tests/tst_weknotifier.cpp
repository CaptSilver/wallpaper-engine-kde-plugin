#include <QtTest>
#include <QDBusConnection>
#include <QFile>
#include "../src/WekNotifier.hpp"

using namespace wekde;

class TestWekNotifier : public QObject {
    Q_OBJECT

private slots:
    void init() {
        if (! QDBusConnection::sessionBus().isConnected())
            QSKIP("no session bus — distrobox without dbus-launch");
    }

    void testWallpaperLoadFailedDoesNotCrash() {
        // The notification daemon may or may not pick up the event in
        // a test environment.  We assert non-crash here; deeper end-to-end
        // is the integration test.
        WekNotifier notifier;
        notifier.wallpaperLoadFailed("12345", "scene.pkg missing");
        QVERIFY(true);
    }

    void testPlaylistAdvancedDoesNotCrash() {
        WekNotifier notifier;
        notifier.playlistAdvanced("12345", "Totoro Spaceship", 3, 30, "Favorites");
        QVERIFY(true);
    }

    void testAssetsMissingDoesNotCrash() {
        WekNotifier notifier;
        notifier.assetsMissing("12345", "scene.pkg / project.json");
        QVERIFY(true);
    }

    void testBackendUnavailableDoesNotCrash() {
        WekNotifier notifier;
        notifier.backendUnavailable("Scene", "plugin lib not found");
        QVERIFY(true);
    }

    // Verify the four event ids match wek.notifyrc.  Parse the notifyrc
    // and assert each [Event/<id>] is referenced.
    void testEventIdsMatchNotifyrc() {
        QFile f(QStringLiteral(WEK_SOURCE_DIR "/data/wek.notifyrc"));
        QVERIFY2(f.open(QIODevice::ReadOnly),
                 qPrintable(QStringLiteral("Failed to open wek.notifyrc at ") + f.fileName()));
        const auto contents = QString::fromUtf8(f.readAll());
        QVERIFY(contents.contains(QStringLiteral("[Event/wallpaperLoadFailed]")));
        QVERIFY(contents.contains(QStringLiteral("[Event/playlistAdvanced]")));
        QVERIFY(contents.contains(QStringLiteral("[Event/assetsMissing]")));
        QVERIFY(contents.contains(QStringLiteral("[Event/backendUnavailable]")));
    }

    // Verify playlistAdvanced defaults to Action=None (no popup) so a
    // 30-item playlist on a 5-min cycle doesn't spam the tray. Other three
    // events default to Action=Popup because they're actionable failures.
    void testPlaylistAdvancedDefaultsToNoPopup() {
        QFile f(QStringLiteral(WEK_SOURCE_DIR "/data/wek.notifyrc"));
        QVERIFY(f.open(QIODevice::ReadOnly));
        const auto contents = QString::fromUtf8(f.readAll());
        const int  idx      = contents.indexOf(QStringLiteral("[Event/playlistAdvanced]"));
        QVERIFY(idx >= 0);
        // The next "Action=" line after the [Event/playlistAdvanced] group
        // header should be Action=None.
        const auto tail = contents.mid(idx);
        const auto nextActionLine =
            tail.section(QStringLiteral("Action="), 1, 1).section('\n', 0, 0);
        QCOMPARE(nextActionLine.trimmed(), QStringLiteral("None"));
    }
};

QTEST_GUILESS_MAIN(TestWekNotifier)
#include "tst_weknotifier.moc"
