// SPDX-License-Identifier: GPL-2.0-only
// Unit tests for wekde::PlaylistManager
//
// Each test gets a fresh QTemporaryDir for XDG_CONFIG_HOME so PlaylistManager
// reads/writes to an isolated tmp path. ~/.config/wekde/playlists.json is the
// canonical location; tests verify the on-disk JSON and the in-memory model.

#include <QtTest>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QSignalSpy>
#include <QSet>

#include "PlaylistManager.hpp"

class TstPlaylistManager : public QObject {
    Q_OBJECT
private:
    QString setupConfigHome(QTemporaryDir& d) {
        qputenv("XDG_CONFIG_HOME", d.path().toLocal8Bit());
        return d.path() + "/wekde/playlists.json";
    }

private slots:
    void emptyOnFreshConstruction() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        wekde::PlaylistManager mgr;
        QVERIFY(mgr.playlists().isEmpty());
        QVERIFY(QFileInfo::exists(path));
    }

    void createPlaylistPersists() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString          path = setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("Morning rotation");
        QVERIFY(! id.isEmpty());
        QCOMPARE(mgr.playlists().size(), 1);
        QCOMPARE(mgr.playlists().first().name, QString("Morning rotation"));

        QFile f(path);
        QVERIFY(f.open(QIODevice::ReadOnly));
        const auto doc = QJsonDocument::fromJson(f.readAll());
        QVERIFY(doc.isObject());
        QCOMPARE(doc.object().value("version").toInt(), 1);
        QCOMPARE(doc.object().value("playlists").toArray().size(), 1);
    }

    void roundtripAcrossConstructions() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);

        QString id;
        {
            wekde::PlaylistManager mgr;
            id = mgr.createPlaylist("My list");
            mgr.setMode(id, wekde::PlaylistMode::Shuffle);
            mgr.setIntervalMin(id, 42);
            mgr.addItem(id, "2800255344");
            mgr.addItem(id, "3633635618", 60);
        }
        {
            wekde::PlaylistManager mgr;
            QCOMPARE(mgr.playlists().size(), 1);
            const auto pl = mgr.playlists().first();
            QCOMPARE(pl.id, id);
            QCOMPARE(pl.name, QString("My list"));
            QCOMPARE(pl.mode, wekde::PlaylistMode::Shuffle);
            QCOMPARE(pl.intervalMin, 42);
            QCOMPARE(pl.items.size(), 2);
            QCOMPARE(pl.items[0].workshopId, QString("2800255344"));
            QVERIFY(! pl.items[0].durationOverrideMin.has_value());
            QCOMPARE(pl.items[1].workshopId, QString("3633635618"));
            QVERIFY(pl.items[1].durationOverrideMin.has_value());
            QCOMPARE(*pl.items[1].durationOverrideMin, 60);
        }
    }

    void corruptJsonMovesAsideAndDefaults() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile pre(path);
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write("{ this is not json");
        pre.close();

        wekde::PlaylistManager mgr;
        QVERIFY(mgr.playlists().isEmpty());
        QDir       dir(QFileInfo(path).absolutePath());
        const auto entries = dir.entryList({ "playlists.json.corrupt-*" }, QDir::Files);
        QVERIFY(! entries.isEmpty());
    }

    void schemaVersionTooNewLeavesFile() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile pre(path);
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write(R"({"version": 99, "playlists": []})");
        pre.close();
        const auto bytesBefore = QFileInfo(path).size();

        wekde::PlaylistManager mgr;
        QVERIFY(mgr.playlists().isEmpty());
        // File untouched (preserves user data through downgrade-then-upgrade).
        QCOMPARE(QFileInfo(path).size(), bytesBefore);
    }

    void deletePlaylistRemovesFromDisk() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString          path = setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("To delete");
        mgr.deletePlaylist(id);
        QVERIFY(mgr.playlists().isEmpty());

        QFile f(path);
        QVERIFY(f.open(QIODevice::ReadOnly));
        const auto doc = QJsonDocument::fromJson(f.readAll());
        QCOMPARE(doc.object().value("playlists").toArray().size(), 0);
    }

    void renameUpdatesAndPersists() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("Before");
        mgr.renamePlaylist(id, "After");
        QCOMPARE(mgr.playlists().first().name, QString("After"));
    }

    void intervalIsClamped() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.setIntervalMin(id, -5);
        QCOMPARE(mgr.playlists().first().intervalMin, 1);
        mgr.setIntervalMin(id, 99999);
        QCOMPARE(mgr.playlists().first().intervalMin, 1440);
    }

    // ── cycle ─────────────────────────────────────────────────────────────────
    void sequentialAdvancesAndWraps() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("Seq");
        mgr.addItem(id, "A");
        mgr.addItem(id, "B");
        mgr.addItem(id, "C");

        QSignalSpy spy(&mgr, &wekde::PlaylistManager::tick);
        QVERIFY(mgr.activate(id));
        // activate emits tick(A) immediately
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.takeFirst().first().toString(), QString("A"));

        const QStringList expected { "B", "C", "A", "B", "C", "A" };
        for (const QString& w : expected) {
            mgr.onTimerTick();
            QCOMPARE(spy.count(), 1);
            QCOMPARE(spy.takeFirst().first().toString(), w);
        }
    }

    void shuffleNoImmediateRepeatAndCovers() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("Shuf");
        for (const QString& w : { "A", "B", "C", "D" }) mgr.addItem(id, w);
        QVERIFY(mgr.setMode(id, wekde::PlaylistMode::Shuffle));
        QVERIFY(mgr.activate(id));

        QString prev = mgr.playlists().first().items[mgr.currentItemIndex()].workshopId;
        QSet<QString> seen { prev };
        for (int i = 0; i < 200; ++i) {
            mgr.onTimerTick();
            const QString cur = mgr.playlists().first().items[mgr.currentItemIndex()].workshopId;
            QVERIFY2(cur != prev,
                     qPrintable(QStringLiteral("immediate repeat at iteration %1: %2")
                                    .arg(i)
                                    .arg(cur)));
            seen.insert(cur);
            prev = cur;
        }
        QCOMPARE(seen, QSet<QString>({ "A", "B", "C", "D" }));
    }

    void perItemDurationOverridesNextInterval() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("D");
        mgr.setIntervalMin(id, 15);
        mgr.addItem(id, "A");
        mgr.addItem(id, "B", 5);
        mgr.addItem(id, "C");

        QVERIFY(mgr.activate(id));
        // After activate, current is item 0 (A), timer should be 15 min.
        QCOMPARE(mgr.nextIntervalMsForTest(), 15 * 60 * 1000);
        mgr.onTimerTick();
        // Now on item 1 (B), interval = 5 min override.
        QCOMPARE(mgr.nextIntervalMsForTest(), 5 * 60 * 1000);
        mgr.onTimerTick();
        // Now on item 2 (C), back to 15 min default.
        QCOMPARE(mgr.nextIntervalMsForTest(), 15 * 60 * 1000);
    }

    void activateUnknownIdFails() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        QSignalSpy             fail(&mgr, &wekde::PlaylistManager::activationFailed);
        QCOMPARE(mgr.activate("nonexistent"), false);
        QCOMPARE(fail.count(), 1);
        QCOMPARE(fail.takeFirst().first().toString(), QString("nonexistent"));
    }

    void activateEmptyPlaylistSuppressesTick() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("Empty");
        QSignalSpy             spy(&mgr, &wekde::PlaylistManager::tick);
        QCOMPARE(mgr.activate(id), false);
        QCOMPARE(spy.count(), 0);
    }

    void deactivateClearsActiveId() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));
        mgr.deactivate();
        QCOMPARE(mgr.activePlaylistId(), QString(""));
    }

    void deletingActivePlaylistDeactivatesFirst() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));
        QVERIFY(mgr.deletePlaylist(id));
        QCOMPARE(mgr.activePlaylistId(), QString(""));
        QVERIFY(mgr.playlists().isEmpty());
    }

    void filteredLibraryRequestsPickAndAcceptsIt() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;

        QSignalSpy reqSpy(&mgr, &wekde::PlaylistManager::requestFilteredPick);
        QSignalSpy tickSpy(&mgr, &wekde::PlaylistManager::tick);

        QVERIFY(mgr.activate(wekde::kFilteredLibraryId));
        QCOMPARE(reqSpy.count(), 1);
        mgr.acceptPick("workshop-xyz");
        QCOMPARE(tickSpy.count(), 1);
        QCOMPARE(tickSpy.takeFirst().first().toString(), QString("workshop-xyz"));
    }

    void skipCurrentAdvancesAndImmediatelyTicks() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");
        mgr.addItem(id, "B");
        mgr.addItem(id, "C");
        QSignalSpy spy(&mgr, &wekde::PlaylistManager::tick);
        QVERIFY(mgr.activate(id)); // ticks "A"
        spy.clear();
        mgr.skipCurrent();
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.takeFirst().first().toString(), QString("B"));
    }

    void skipBailsAfter8ConsecutiveSkips() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        for (int i = 0; i < 5; ++i) mgr.addItem(id, QString("W%1").arg(i));
        QVERIFY(mgr.activate(id));
        QSignalSpy spy(&mgr, &wekde::PlaylistManager::tick);
        for (int i = 0; i < 8; ++i) mgr.skipCurrent();
        const int countBefore = spy.count();
        mgr.skipCurrent(); // 9th skip — bail
        QCOMPARE(spy.count(), countBefore); // no new tick
    }

    // ── migration + pause/resume ──────────────────────────────────────────────
    void migrationFiresOnFirstRunWithRandomizeOn() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QVERIFY(! QFileInfo::exists(path)); // truly fresh

        wekde::PlaylistManager mgr;
        // After load, the file exists with empty playlists. Migration is
        // performed by the QML side (which reads RandomizeWallpaper from
        // plasmoid config and calls mgr.activate(__filtered_library__)).
        // Here we verify activate() succeeds against the sentinel even
        // with no user playlists.
        QVERIFY(mgr.activate(wekde::kFilteredLibraryId));
        QCOMPARE(mgr.activePlaylistId(), QString(wekde::kFilteredLibraryId));
    }

    void migrationDoesNotFireWhenFileAlreadyExists() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile pre(path);
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write(R"({"version": 1, "playlists": []})");
        pre.close();
        const auto bytesBefore = QFileInfo(path).size();

        wekde::PlaylistManager mgr;
        // Construction must not rewrite the file — load() bails before persist()
        // when the file already exists.
        QCOMPARE(QFileInfo(path).size(), bytesBefore);
    }

    void pauseAndResumeKeepsStateConsistent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.setIntervalMin(id, 1); // 1 min = 60000 ms
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));
        // Active + armed at 60000ms.
        QCOMPARE(mgr.nextIntervalMsForTest(), 60000);
        // Pause + resume — active id and current index unchanged.
        mgr.pauseTicks();
        mgr.resumeTicks();
        QCOMPARE(mgr.activePlaylistId(), id);
        QCOMPARE(mgr.currentItemIndex(), 0);
    }
};

QTEST_GUILESS_MAIN(TstPlaylistManager)
#include "tst_playlist_manager.moc"
