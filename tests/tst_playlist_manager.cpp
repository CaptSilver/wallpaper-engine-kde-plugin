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

#include "Playlist.hpp"
#include "PlaylistManager.hpp"
#include "PlaylistsModel.hpp"
#include "PlaylistItemsModel.hpp"

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
        const QString          path = setupConfigHome(d);
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
            mgr.addItem(id, "3633635618");
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
            QCOMPARE(pl.items[1].workshopId, QString("3633635618"));
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

        QString       prev = mgr.playlists().first().items[mgr.currentItemIndex()].workshopId;
        QSet<QString> seen { prev };
        for (int i = 0; i < 200; ++i) {
            mgr.onTimerTick();
            const QString cur = mgr.playlists().first().items[mgr.currentItemIndex()].workshopId;
            QVERIFY2(
                cur != prev,
                qPrintable(QStringLiteral("immediate repeat at iteration %1: %2").arg(i).arg(cur)));
            seen.insert(cur);
            prev = cur;
        }
        QCOMPARE(seen, QSet<QString>({ "A", "B", "C", "D" }));
    }

    void nextIntervalUsesPlaylistDefault() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("D");
        mgr.setIntervalMin(id, 15);
        mgr.addItem(id, "A");
        mgr.addItem(id, "B");
        mgr.addItem(id, "C");

        QVERIFY(mgr.activate(id));
        QCOMPARE(mgr.nextIntervalMsForTest(), 15 * 60 * 1000);
        mgr.onTimerTick();
        QCOMPARE(mgr.nextIntervalMsForTest(), 15 * 60 * 1000);
        mgr.onTimerTick();
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
        QSignalSpy tickSpy(&mgr, &wekde::PlaylistManager::tick);
        QSignalSpy failSpy(&mgr, &wekde::PlaylistManager::activationFailed);
        for (int i = 0; i < 8; ++i) mgr.skipCurrent();
        const int countBefore = tickSpy.count();
        mgr.skipCurrent();                      // 9th skip — bail
        QCOMPARE(tickSpy.count(), countBefore); // no new tick
        // Bail must deactivate: the user sees the playlist toggle off
        // instead of a silently-wedged playlist that emits nothing.
        QCOMPARE(mgr.activePlaylistId(), QString(""));
        QCOMPARE(failSpy.count(), 1);
        QCOMPARE(failSpy.takeFirst().first().toString(), id);
    }

    // Consecutive skip counter resets on a successful tick — a playlist
    // with one bad item out of many shouldn't accumulate toward bail.
    void skipCounterResetsOnSuccessfulTick() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        for (int i = 0; i < 3; ++i) mgr.addItem(id, QString("W%1").arg(i));
        QVERIFY(mgr.activate(id));

        // Skip 5 times — counter at 5/8.
        for (int i = 0; i < 5; ++i) mgr.skipCurrent();
        QCOMPARE(mgr.activePlaylistId(), id); // still active

        // A normal timer tick advances and resets the counter.
        mgr.onTimerTick();

        // Now skip 5 more — should still not bail (counter started fresh).
        for (int i = 0; i < 5; ++i) mgr.skipCurrent();
        QCOMPARE(mgr.activePlaylistId(), id);
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

    // moveItem persists immediately — there's no Apply gate on playlist
    // ops (per plasma-cfg-vs-live-writes.md, playlists.json is the source
    // of truth, NOT cfg_*). Cancel on the dialog therefore can't revert
    // a drag-reorder; the test exists to lock that semantic in place so
    // any future "buffered playlist edits" refactor has to consciously
    // change it.
    void moveItemPersistsImmediatelyNoCancelGate() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);

        QString id;
        {
            wekde::PlaylistManager mgr;
            id = mgr.createPlaylist("R");
            mgr.addItem(id, "A");
            mgr.addItem(id, "B");
            mgr.addItem(id, "C");
            mgr.moveItem(id, 0, 2); // A → end → order becomes [B, C, A]
        }
        // Re-instantiate — disk state must reflect the move even though
        // the user didn't "Apply" anything.
        {
            wekde::PlaylistManager mgr;
            const auto             pl = mgr.playlists().first();
            QCOMPARE(pl.items.size(), 3);
            QCOMPARE(pl.items[0].workshopId, QString("B"));
            QCOMPARE(pl.items[1].workshopId, QString("C"));
            QCOMPARE(pl.items[2].workshopId, QString("A"));
        }
    }

    // Persistence recovery — atomicWriteJson writes to <path>.tmp, fsync,
    // then rename(2). A crash between flush and rename leaves an orphan
    // .tmp next to a valid playlists.json. PlaylistManager must load the
    // real file and treat the orphan as benign clutter (next persist
    // overwrites it cleanly).
    void orphanTmpDoesNotPoisonLoad() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QDir().mkpath(QFileInfo(path).absolutePath());

        // Write a valid playlists.json with one entry.
        {
            wekde::PlaylistManager mgr;
            const QString          id = mgr.createPlaylist("Survives");
            mgr.addItem(id, "Wp1");
        }
        QVERIFY(QFile::exists(path));

        // Drop a stray .tmp file with garbage — simulates the
        // post-flush-pre-rename crash.
        const QString tmp = path + ".tmp";
        QFile         orphan(tmp);
        QVERIFY(orphan.open(QIODevice::WriteOnly));
        orphan.write("{this is not valid json yet — half written");
        orphan.close();

        // Re-construct: real file must still load cleanly. Orphan
        // .tmp is irrelevant to load().
        {
            wekde::PlaylistManager mgr;
            QCOMPARE(mgr.playlists().size(), 1);
            QCOMPARE(mgr.playlists().first().name, QString("Survives"));
        }

        // Next persist must overwrite cleanly — the rename(2) step replaces
        // .tmp via tmpfile creation+rename, so the stale orphan ends up
        // either gone or overwritten on the next write.
        {
            wekde::PlaylistManager mgr;
            mgr.createPlaylist("Another");
        }
        QVERIFY(QFile::exists(path));
        // The orphan should not block future writes; it may be overwritten
        // or removed. The key invariant is that the canonical file is
        // still valid JSON.
        QFile reread(path);
        QVERIFY(reread.open(QIODevice::ReadOnly));
        const auto doc = QJsonDocument::fromJson(reread.readAll());
        QVERIFY(! doc.isNull());
        QVERIFY(doc.object().value("playlists").isArray());
    }

    // Schema corruption: valid JSON but wrong shape. Real-world bug from
    // disk-full failures or third-party config editors that produce
    // syntactically valid JSON with semantically wrong fields.
    void schemaShapeWrong_doesNotCrash() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QDir().mkpath(QFileInfo(path).absolutePath());

        // playlists is a STRING instead of an array — must not crash on load.
        QFile pre(path);
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write(R"({"version": 1, "playlists": "oops not an array"})");
        pre.close();

        wekde::PlaylistManager mgr;
        // Should fall back to empty rather than crash or assert.
        QCOMPARE(mgr.playlists().size(), 0);
    }

    // Schema corruption: entry missing required fields. The reader should
    // skip or default rather than produce a half-formed Playlist.
    void schemaEntryMissingFields_doesNotCrash() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d);
        QDir().mkpath(QFileInfo(path).absolutePath());

        QFile pre(path);
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write(R"({
            "version": 1,
            "playlists": [
                {"missing_id_and_name": true},
                {"id": "", "name": ""}
            ]
        })");
        pre.close();

        wekde::PlaylistManager mgr;
        // No assertion on count — implementation defines whether to skip
        // or accept-default the malformed entries. The contract is "don't
        // crash"; both load policies satisfy it.
        Q_UNUSED(mgr);
    }

    // ── Direct JSON round-trips for Playlist + PlaylistItem helpers ─────────
    // The reset_wallpaper_config + writeWallpaperConfig + migration paths
    // depend on these being faithful encoders. Going via PlaylistManager's
    // end-to-end persist masks single-field encoder regressions.

    void playlistItem_jsonRoundTrip_idempotent() {
        wekde::PlaylistItem original;
        original.workshopId = "2800255344";
        const auto json     = wekde::playlistItemToJson(original);
        const auto round    = wekde::playlistItemFromJson(json);
        QCOMPARE(round.workshopId, original.workshopId);
    }

    void playlistItem_jsonTolerantToUnknownFields() {
        // The removed durationOverrideMin field landed silently in
        // playlistFromJson — this test pins that unknown JSON fields are
        // ignored so future schema additions don't blow up old binaries.
        QJsonObject obj;
        obj["workshop_id"]           = "abc";
        obj["duration_override_min"] = 42;         // removed
        obj["some_future_field"]     = "anything"; // unknown
        obj["extra_nested"]          = QJsonObject { { "x", 1 } };
        const auto it                = wekde::playlistItemFromJson(obj);
        QCOMPARE(it.workshopId, QString("abc"));
    }

    void playlist_jsonRoundTrip_preservesAllFields() {
        wekde::Playlist original;
        original.id          = "uuid-1234";
        original.name        = "Round Trip";
        original.mode        = wekde::PlaylistMode::Shuffle;
        original.intervalMin = 42;
        original.created     = 1700000000;
        original.modified    = 1700000100;
        wekde::PlaylistItem a;
        a.workshopId = "A";
        original.items.append(a);
        wekde::PlaylistItem b;
        b.workshopId = "B";
        original.items.append(b);

        const auto json  = wekde::playlistToJson(original);
        const auto round = wekde::playlistFromJson(json);
        QCOMPARE(round.id, original.id);
        QCOMPARE(round.name, original.name);
        QCOMPARE(round.mode, original.mode);
        QCOMPARE(round.intervalMin, original.intervalMin);
        QCOMPARE(round.created, original.created);
        QCOMPARE(round.modified, original.modified);
        QCOMPARE(round.items.size(), 2);
        QCOMPARE(round.items[0].workshopId, QString("A"));
        QCOMPARE(round.items[1].workshopId, QString("B"));
    }

    void playlistMode_fromString_acceptsKnownValues() {
        QCOMPARE(wekde::playlistModeFromString("sequential"), wekde::PlaylistMode::Sequential);
        QCOMPARE(wekde::playlistModeFromString("shuffle"), wekde::PlaylistMode::Shuffle);
    }

    void playlistMode_fromString_unknownReturnsFallback() {
        // Default fallback is Sequential.
        QCOMPARE(wekde::playlistModeFromString(""), wekde::PlaylistMode::Sequential);
        QCOMPARE(wekde::playlistModeFromString("nonsense"), wekde::PlaylistMode::Sequential);
        // Explicit fallback honored.
        QCOMPARE(wekde::playlistModeFromString("x", wekde::PlaylistMode::Shuffle),
                 wekde::PlaylistMode::Shuffle);
    }

    void clampIntervalMin_boundaries() {
        // Min boundary.
        QCOMPARE(wekde::clampIntervalMin(0), 1);
        QCOMPARE(wekde::clampIntervalMin(-100), 1);
        QCOMPARE(wekde::clampIntervalMin(INT_MIN), 1);
        // Mid range — passthrough.
        QCOMPARE(wekde::clampIntervalMin(1), 1);
        QCOMPARE(wekde::clampIntervalMin(15), 15);
        QCOMPARE(wekde::clampIntervalMin(1440), 1440);
        // Max boundary.
        QCOMPARE(wekde::clampIntervalMin(1441), 1440);
        QCOMPARE(wekde::clampIntervalMin(INT_MAX), 1440);
    }

    // setFilteredLibraryIntervalMin re-arms the live timer if the user
    // changes the Randomize Timer slider while Filtered Library is active.
    // Without the re-arm, the new interval only kicks in on the NEXT
    // natural tick — invisible to the user. Anchors the
    // `m_activeId == kFilteredLibraryId && m_timer.isActive()` branch.
    void setFilteredLibraryIntervalMin_reArmsActiveTimer() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;

        // Arm: filtered library + initial interval.
        mgr.setFilteredLibraryIntervalMin(10);
        QVERIFY(mgr.activate(wekde::kFilteredLibraryId));
        // activate does NOT arm the timer for the filtered library because
        // tick goes through requestFilteredPick. Manually arm via
        // acceptPick — that's the production path after the QML side
        // returns a chosen workshopId.
        mgr.acceptPick("workshop-xyz");
        QCOMPARE(mgr.nextIntervalMsForTest(), 10 * 60 * 1000);

        // Change the interval — re-arm branch should fire.
        mgr.setFilteredLibraryIntervalMin(45);
        QCOMPARE(mgr.nextIntervalMsForTest(), 45 * 60 * 1000);

        // Clamping verified at the boundary: too-large → 1440 cap.
        mgr.setFilteredLibraryIntervalMin(99999);
        QCOMPARE(mgr.nextIntervalMsForTest(), 1440 * 60 * 1000);
    }

    // setFilteredLibraryIntervalMin on an INACTIVE filtered library only
    // stores the value — it doesn't try to arm a timer that has no source.
    void setFilteredLibraryIntervalMin_inactiveStoresOnly() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        mgr.setFilteredLibraryIntervalMin(30);
        // No active playlist → nextIntervalMsForTest reports 0 regardless.
        QCOMPARE(mgr.nextIntervalMsForTest(), 0);
        // Subsequent activation honors the stored value.
        QVERIFY(mgr.activate(wekde::kFilteredLibraryId));
        mgr.acceptPick("x");
        QCOMPARE(mgr.nextIntervalMsForTest(), 30 * 60 * 1000);
    }

    // Pause/resume edge cases. The clamp `std::max<qint64>(0, total -
    // elapsed)` at PlaylistManager.cpp:392 is a Mull mutation target —
    // dropping it lets m_remainingMs go negative, which resumeTicks
    // would silently reject (m_remainingMs < 0 short-circuits the
    // re-arm). These tests don't time-travel to hit elapsed > total
    // directly (would need a 1+ minute wait), but they pin the
    // invariants that protect callers.

    void pauseTicks_isNoOpWhenTimerNotActive() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        // No active playlist → timer never armed.
        mgr.pauseTicks();
        mgr.resumeTicks();
        // Followed by activate: arming + tick path should still work
        // (pauseTicks shouldn't have poisoned internal state).
        const QString id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));
        QCOMPARE(mgr.activePlaylistId(), id);
    }

    void resumeTicks_earlyReturnWhenNoPriorPause() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));
        // m_remainingMs == -1 (default sentinel). resumeTicks must be
        // safe — no double-arm, no crash.
        mgr.resumeTicks();
        mgr.resumeTicks();
        QCOMPARE(mgr.activePlaylistId(), id);
    }

    void pauseThenResume_restoresActiveState() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.setIntervalMin(id, 15);
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));
        const auto activeBefore = mgr.activePlaylistId();
        const auto idxBefore    = mgr.currentItemIndex();
        mgr.pauseTicks();
        mgr.resumeTicks();
        // Active id + index survive a pause/resume round-trip.
        QCOMPARE(mgr.activePlaylistId(), activeBefore);
        QCOMPARE(mgr.currentItemIndex(), idxBefore);
    }

    // Mull-target: pickShuffle force-different branch. With size==2 and
    // the first random bounded() landing on cur, the implementation
    // tries a second pick. If both land on cur it forces `(cur+1) % size`.
    // Hammer the path with many ticks: across N runs the result must
    // NEVER equal the previous index (the no-immediate-repeat guarantee).
    void shuffle_neverImmediatelyRepeats_evenAtSize2() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("Two");
        mgr.addItem(id, "A");
        mgr.addItem(id, "B");
        QVERIFY(mgr.setMode(id, wekde::PlaylistMode::Shuffle));
        QVERIFY(mgr.activate(id));
        QString prev = mgr.playlists().first().items[mgr.currentItemIndex()].workshopId;
        for (int i = 0; i < 500; ++i) {
            mgr.onTimerTick();
            const QString cur = mgr.playlists().first().items[mgr.currentItemIndex()].workshopId;
            QVERIFY2(
                cur != prev,
                qPrintable(QStringLiteral("size=2 shuffle repeat at iter %1: %2").arg(i).arg(cur)));
            prev = cur;
        }
    }

    // ── PlaylistsModel + PlaylistItemsModel direct tests ────────────────────
    // These QAbstractListModel subclasses are the QML data contract for
    // PlaylistsPage. A typo in a role name silently breaks every
    // `delegate { Text { text: model.name } }`; a missing bounds check
    // crashes the dialog on a corrupted-on-disk playlist.

    void playlistsModel_roleNames_exactlyMatchQmlContract() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const auto*            model = mgr.playlistsModel();
        QVERIFY(model != nullptr);
        const auto roles = model->roleNames();
        // The QML side reads `model.id`, `name`, `mode`, `intervalMin`,
        // `itemCount`. Any rename of these keys cascades into every
        // PlaylistsPage delegate + AddToPlaylistMenu delegate.
        QCOMPARE(roles.value(wekde::PlaylistsModel::IdRole), QByteArray("id"));
        QCOMPARE(roles.value(wekde::PlaylistsModel::NameRole), QByteArray("name"));
        QCOMPARE(roles.value(wekde::PlaylistsModel::ModeRole), QByteArray("mode"));
        QCOMPARE(roles.value(wekde::PlaylistsModel::IntervalMinRole), QByteArray("intervalMin"));
        QCOMPARE(roles.value(wekde::PlaylistsModel::ItemCountRole), QByteArray("itemCount"));
    }

    void playlistsModel_dataInvalidIndex_returnsInvalid() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const auto*            model = mgr.playlistsModel();
        // Invalid QModelIndex, negative row, past-end row, unknown role —
        // all defensive contract: no crash, returns invalid QVariant.
        QVERIFY(! model->data(QModelIndex(), wekde::PlaylistsModel::IdRole).isValid());
        QVERIFY(! model->data(model->index(-1, 0), wekde::PlaylistsModel::IdRole).isValid());
        QVERIFY(! model->data(model->index(999, 0), wekde::PlaylistsModel::IdRole).isValid());
        mgr.createPlaylist("X");
        QVERIFY(! model->data(model->index(0, 0), Qt::UserRole + 9999).isValid());
    }

    void playlistsModel_rowCountWithValidParent_returnsZero() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const auto*            model = mgr.playlistsModel();
        mgr.createPlaylist("X");
        // QAbstractListModel contract: rowCount with valid parent (i.e.
        // anything that isn't the root) returns 0 — there are no nested
        // children.
        QCOMPARE(model->rowCount(QModelIndex()), 1);
        QCOMPARE(model->rowCount(model->index(0, 0)), 0);
    }

    void playlistsModel_notifyRowChanged_outOfRangeIsNoOp() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        auto*                  model = mgr.playlistsModel();
        QSignalSpy             spy(model, &QAbstractListModel::dataChanged);
        model->notifyRowChanged(-1);
        model->notifyRowChanged(999);
        // Out-of-range must not emit a bogus dataChanged that would
        // poison views asking for that row.
        QCOMPARE(spy.count(), 0);
    }

    void playlistItemsModel_roleNames_exactlyMatchQmlContract() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id    = mgr.createPlaylist("X");
        const auto*            model = mgr.itemsModel(id);
        QVERIFY(model != nullptr);
        const auto roles = model->roleNames();
        QCOMPARE(roles.value(wekde::PlaylistItemsModel::WorkshopIdRole), QByteArray("workshopId"));
        // After the duration-override removal, the role hash size is 1.
        QCOMPARE(roles.size(), 1);
    }

    void playlistItemsModel_unknownPlaylistId_rowCountZero() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        // itemsModel on an id that doesn't exist still returns a valid
        // model pointer (cached); rowCount on it must be 0, not crash.
        auto* model = mgr.itemsModel("never-created");
        QVERIFY(model != nullptr);
        QCOMPARE(model->rowCount(), 0);
        QVERIFY(
            ! model->data(model->index(0, 0), wekde::PlaylistItemsModel::WorkshopIdRole).isValid());
    }

    void playlistItemsModel_itemsCache_returnsSamePointer() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id     = mgr.createPlaylist("X");
        auto*                  first  = mgr.itemsModel(id);
        auto*                  second = mgr.itemsModel(id);
        QCOMPARE(first, second); // cached
        mgr.addItem(id, "wp-1");
        auto* third = mgr.itemsModel(id);
        QCOMPARE(first, third); // cache survives mutations
    }

    // ── PlaylistManager unhappy paths — all must return false / no-op /
    //    no-crash. Currently uncovered branches a Mull mutation could
    //    silently flip (return true from a guard that meant to return false,
    //    or drop a bounds check entirely).

    void unhappyPaths_returnFalseWithoutSideEffect() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");
        mgr.addItem(id, "B");

        // addItem on unknown playlist
        QCOMPARE(mgr.addItem("nonexistent", "ZZ"), false);
        QCOMPARE(mgr.playlists().first().items.size(), 2);

        // removeItem out of range (both directions) + unknown id
        QCOMPARE(mgr.removeItem(id, -1), false);
        QCOMPARE(mgr.removeItem(id, 999), false);
        QCOMPARE(mgr.removeItem("nonexistent", 0), false);
        QCOMPARE(mgr.playlists().first().items.size(), 2);

        // moveItem self-move + out of range + unknown
        QCOMPARE(mgr.moveItem(id, 0, 0), true); // self-move returns true (early-out)
        QCOMPARE(mgr.moveItem(id, 0, 999), false);
        QCOMPARE(mgr.moveItem(id, -1, 0), false);
        QCOMPARE(mgr.moveItem("nonexistent", 0, 1), false);
        QCOMPARE(mgr.playlists().first().items[0].workshopId, QString("A"));

        // deletePlaylist of nonexistent
        QCOMPARE(mgr.deletePlaylist("nonexistent"), false);
        QCOMPARE(mgr.playlists().size(), 1);

        // renamePlaylist of nonexistent
        QCOMPARE(mgr.renamePlaylist("nonexistent", "NewName"), false);

        // setMode / setIntervalMin of nonexistent
        QCOMPARE(mgr.setMode("nonexistent", 1), false);
        QCOMPARE(mgr.setIntervalMin("nonexistent", 30), false);
    }

    // setActivePlaylistId is the Q_PROPERTY setter behind the
    // Q_PROPERTY(activePlaylistId WRITE setActivePlaylistId) — uncovered
    // early-return + delegation branches.
    void setActivePlaylistId_idempotentAndDelegating() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "A");

        QSignalSpy spy(&mgr, &wekde::PlaylistManager::activePlaylistIdChanged);

        // Activate via the property setter (was uncovered).
        mgr.setActivePlaylistId(id);
        QCOMPARE(mgr.activePlaylistId(), id);
        const int afterActivate = spy.count();
        QVERIFY(afterActivate >= 1);

        // Idempotent: same id → no-op early-return.
        mgr.setActivePlaylistId(id);
        QCOMPARE(spy.count(), afterActivate);

        // Empty string → deactivate path.
        mgr.setActivePlaylistId("");
        QCOMPARE(mgr.activePlaylistId(), QString(""));
    }

    // playlistContains — Q_INVOKABLE used by AddToPlaylistMenu to disable
    // already-added rows. Locks every documented branch.
    void playlistContains_allBranches() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        const QString          id = mgr.createPlaylist("X");
        mgr.addItem(id, "wp-A");
        mgr.addItem(id, "wp-B");

        QVERIFY(mgr.playlistContains(id, "wp-A"));
        QVERIFY(mgr.playlistContains(id, "wp-B"));
        QVERIFY(! mgr.playlistContains(id, "wp-NOT-HERE"));
        // Empty playlistId / empty workshopid → false (never crash).
        QVERIFY(! mgr.playlistContains("", "wp-A"));
        QVERIFY(! mgr.playlistContains(id, ""));
        // Filtered Library sentinel is never a manual-add target →
        // contains always false even if the id somehow matched.
        QVERIFY(! mgr.playlistContains(wekde::kFilteredLibraryId, "wp-A"));
        // Unknown id → false.
        QVERIFY(! mgr.playlistContains("not-a-playlist", "wp-A"));
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

    // ── editorMode + reload + persisted ───────────────────────────────────
    // These tests pin the "single mgr shared via plasmoid lifecycle"
    // semantics: dialog mgr (editorMode=true) is a UI-only shadow that
    // doesn't tick or arm a timer, even when its activate() is called.
    // The runtime mgr (editorMode=false) is the sole playback owner, and
    // reload() lets it pick up the dialog's persisted edits without a
    // plasmashell restart.

    // editor mgr.activate sets m_activeId for UI display but emits NO
    // `tick` and arms NO timer. Critical: prevents the dialog mgr from
    // racing the runtime mgr's playback cycle (different shuffle picks +
    // independent timers writing to CurrentItemIndex).
    void editorMode_activateDoesNotTickOrArm() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        mgr.setEditorMode(true);
        QCOMPARE(mgr.editorMode(), true);

        const QString id = mgr.createPlaylist("Editor");
        mgr.setMode(id, wekde::PlaylistMode::Shuffle);
        mgr.addItem(id, "A");
        mgr.addItem(id, "B");

        QSignalSpy tickSpy(&mgr, &wekde::PlaylistManager::tick);
        QSignalSpy idSpy(&mgr, &wekde::PlaylistManager::activePlaylistIdChanged);

        QVERIFY(mgr.activate(id));
        QCOMPARE(mgr.activePlaylistId(), id); // tracked for UI
        QCOMPARE(mgr.currentItemIndex(), 0);  // editor never picks shuffle index
        QCOMPARE(tickSpy.count(), 0);         // CRITICAL: no tick
        QVERIFY(idSpy.count() >= 1);          // UI gets the activate signal
        // No timer armed → nextIntervalMsForTest is what the mgr WOULD use,
        // but isActive is the real "would tick" check. Quick proxy: drive
        // onTimerTick manually and verify the editor short-circuit fires
        // before the cycle picks a new index.
        const int before = mgr.currentItemIndex();
        mgr.onTimerTick();
        QCOMPARE(mgr.currentItemIndex(), before); // editor onTimerTick short-circuits
        QCOMPARE(tickSpy.count(), 0);
    }

    // editor mgr.activate is idempotent on same id — matches non-editor
    // semantics. Without the early-return, a re-activation would emit
    // spurious activePlaylistIdChanged + reset currentItemIndex (which
    // would race the runtime if the runtime had advanced past 0).
    void editorMode_activateIdempotent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        mgr.setEditorMode(true);
        const QString id = mgr.createPlaylist("E");
        mgr.addItem(id, "A");

        QVERIFY(mgr.activate(id));
        QSignalSpy idSpy(&mgr, &wekde::PlaylistManager::activePlaylistIdChanged);
        QVERIFY(mgr.activate(id)); // same id again
        QCOMPARE(idSpy.count(), 0);
    }

    // editor mgr.deactivate clears m_activeId without touching the timer
    // (already not armed). Mirrors the runtime deactivate signal pattern
    // so the controller's onActivePlaylistIdChanged still fires.
    void editorMode_deactivate() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        mgr.setEditorMode(true);
        const QString id = mgr.createPlaylist("E");
        mgr.addItem(id, "A");
        QVERIFY(mgr.activate(id));

        QSignalSpy idSpy(&mgr, &wekde::PlaylistManager::activePlaylistIdChanged);
        mgr.deactivate();
        QCOMPARE(mgr.activePlaylistId(), QString(""));
        QVERIFY(idSpy.count() >= 1);
        // Idempotent.
        idSpy.clear();
        mgr.deactivate();
        QCOMPARE(idSpy.count(), 0);
    }

    // acceptPick + onTimerTick in editor mode must NOT emit tick — the
    // editor is forbidden from driving the wallpaper cycle.
    void editorMode_acceptPickAndTickAreInert() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        mgr.setEditorMode(true);
        mgr.setFilteredLibraryIntervalMin(10);
        QVERIFY(mgr.activate(wekde::kFilteredLibraryId));

        QSignalSpy tickSpy(&mgr, &wekde::PlaylistManager::tick);
        QSignalSpy reqSpy(&mgr, &wekde::PlaylistManager::requestFilteredPick);
        mgr.acceptPick("workshop-xyz");
        QCOMPARE(tickSpy.count(), 0);
        QCOMPARE(reqSpy.count(), 0);
        mgr.onTimerTick();
        QCOMPARE(tickSpy.count(), 0);
        QCOMPARE(reqSpy.count(), 0);
    }

    // setEditorMode is idempotent + emits editorModeChanged on flip.
    void editorMode_setterFires() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        QSignalSpy             spy(&mgr, &wekde::PlaylistManager::editorModeChanged);
        QCOMPARE(mgr.editorMode(), false);
        mgr.setEditorMode(false); // idempotent
        QCOMPARE(spy.count(), 0);
        mgr.setEditorMode(true);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(mgr.editorMode(), true);
        mgr.setEditorMode(true); // idempotent
        QCOMPARE(spy.count(), 1);
        mgr.setEditorMode(false);
        QCOMPARE(spy.count(), 2);
    }

    // persist() emits persisted() on success. This is the signal the
    // dialog's PlaylistController connects to so it can bump
    // cfg_PlaylistsReloadSeq. Every CRUD path (create / rename / setMode
    // / setIntervalMin / addItem / removeItem / moveItem / delete) routes
    // through persist() → at least one persisted() emit per op.
    void persisted_emittedAfterEveryCrud() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        QSignalSpy             spy(&mgr, &wekde::PlaylistManager::persisted);

        // create → persist
        const QString id = mgr.createPlaylist("P");
        QVERIFY(spy.count() >= 1);
        spy.clear();

        mgr.renamePlaylist(id, "P2");
        QCOMPARE(spy.count(), 1);
        spy.clear();

        mgr.setMode(id, wekde::PlaylistMode::Shuffle);
        QCOMPARE(spy.count(), 1);
        spy.clear();

        mgr.setIntervalMin(id, 30);
        QCOMPARE(spy.count(), 1);
        spy.clear();

        mgr.addItem(id, "A");
        QCOMPARE(spy.count(), 1);
        spy.clear();

        mgr.addItem(id, "B");
        spy.clear();

        mgr.moveItem(id, 0, 1);
        QCOMPARE(spy.count(), 1);
        spy.clear();

        mgr.removeItem(id, 0);
        QCOMPARE(spy.count(), 1);
        spy.clear();

        mgr.deletePlaylist(id);
        QCOMPARE(spy.count(), 1);
    }

    // F17: persist() now calls FileHelper::atomicWriteJson statically instead
    // of constructing a throwaway FileHelper, whose ctor unconditionally
    // mkpaths the (unrelated) wallpaper config dir as a side effect. A
    // playlist save must not create ".../wekde/wallpaper/".
    void persist_doesNotCreateWallpaperConfigDirSideEffect() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = setupConfigHome(d); // redirects XDG_CONFIG_HOME
        // The wallpaper config dir lives beside playlists.json under wekde/.
        const QString wallpaperDir = QFileInfo(path).absolutePath() + "/wallpaper";

        wekde::PlaylistManager mgr;       // ctor load() → persist() (fresh file)
        mgr.createPlaylist("Side FX");    // another persist()
        QVERIFY(QFileInfo::exists(path)); // sanity: playlists.json written here

        // Pre-fix, the throwaway FileHelper ctor created this dir on persist.
        QVERIFY(! QFileInfo::exists(wallpaperDir));
    }

    // reload() re-reads playlists.json + preserves the active playlist /
    // index when possible. The runtime ctrl calls this after the dialog
    // bumps the reload-seq so user edits propagate without a plasmashell
    // restart. Uses two mgrs sharing the same XDG_CONFIG_HOME so that
    // editor mgr A's persist is visible to runtime mgr B's reload.
    void reload_picksUpDialogEditedInterval() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        QString id;
        {
            wekde::PlaylistManager dialogMgr; // editorMode=false, fine here
            id = dialogMgr.createPlaylist("Shared");
            dialogMgr.addItem(id, "A");
            dialogMgr.setIntervalMin(id, 15);
        }
        wekde::PlaylistManager runtimeMgr;
        QVERIFY(runtimeMgr.activate(id));
        QCOMPARE(runtimeMgr.nextIntervalMsForTest(), 15 * 60 * 1000);

        // Dialog edits the interval (separate mgr instance, same disk file).
        {
            wekde::PlaylistManager dialogMgr;
            dialogMgr.setEditorMode(true);
            QVERIFY(dialogMgr.setIntervalMin(id, 45));
        }
        // Before reload: runtimeMgr's in-memory pl->intervalMin is stale.
        QCOMPARE(runtimeMgr.nextIntervalMsForTest(), 15 * 60 * 1000);
        // reload() → pulls fresh data from disk.
        runtimeMgr.reload();
        QCOMPARE(runtimeMgr.nextIntervalMsForTest(), 45 * 60 * 1000);
        QCOMPARE(runtimeMgr.activePlaylistId(), id); // active preserved
    }

    // reload preserves currentItemIndex when valid + clamps when the
    // dialog removed items past it. This is the "user removed items
    // while runtime was mid-cycle" case.
    void reload_clampsIndexWhenItemsRemoved() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        QString id;
        {
            wekde::PlaylistManager initMgr;
            id = initMgr.createPlaylist("X");
            initMgr.addItem(id, "A");
            initMgr.addItem(id, "B");
            initMgr.addItem(id, "C");
        }
        wekde::PlaylistManager runtimeMgr;
        QVERIFY(runtimeMgr.activate(id));
        // Drive currentIndex to 2 (last item) sequentially.
        runtimeMgr.onTimerTick(); // 0 → 1
        runtimeMgr.onTimerTick(); // 1 → 2
        QCOMPARE(runtimeMgr.currentItemIndex(), 2);

        // Dialog removes items B + C → only A remains at index 0.
        {
            wekde::PlaylistManager dialogMgr;
            dialogMgr.setEditorMode(true);
            QVERIFY(dialogMgr.removeItem(id, 2));
            QVERIFY(dialogMgr.removeItem(id, 1));
        }
        runtimeMgr.reload();
        QCOMPARE(runtimeMgr.activePlaylistId(), id); // still active
        QCOMPARE(runtimeMgr.currentItemIndex(), 0);  // clamped to new size-1
    }

    // reload clears active state when the dialog deleted the active
    // playlist outright. Runtime can't keep ticking a stale id.
    void reload_clearsWhenActivePlaylistDeleted() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        QString id;
        {
            wekde::PlaylistManager initMgr;
            id = initMgr.createPlaylist("Y");
            initMgr.addItem(id, "A");
        }
        wekde::PlaylistManager runtimeMgr;
        QVERIFY(runtimeMgr.activate(id));
        QCOMPARE(runtimeMgr.activePlaylistId(), id);

        {
            wekde::PlaylistManager dialogMgr;
            dialogMgr.setEditorMode(true);
            QVERIFY(dialogMgr.deletePlaylist(id));
        }
        QSignalSpy idSpy(&runtimeMgr, &wekde::PlaylistManager::activePlaylistIdChanged);
        runtimeMgr.reload();
        QCOMPARE(runtimeMgr.activePlaylistId(), QString(""));
        QVERIFY(idSpy.count() >= 1);
    }

    // reload on an inactive mgr is a clean no-op (no signals, no crash).
    // Anchors the savedActiveId.isEmpty() early-return.
    void reload_inactiveIsNoOp() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        QSignalSpy             idSpy(&mgr, &wekde::PlaylistManager::activePlaylistIdChanged);
        QSignalSpy             idxSpy(&mgr, &wekde::PlaylistManager::currentItemIndexChanged);
        mgr.reload();
        QCOMPARE(idSpy.count(), 0);
        QCOMPARE(idxSpy.count(), 0);
        QCOMPARE(mgr.activePlaylistId(), QString(""));
    }

    // reload on the Filtered Library re-arms with the latest interval
    // (the dialog may have changed SwitchTimer in between). Anchors the
    // `savedActiveId == kFilteredLibraryId` branch.
    void reload_filteredLibraryRePicksUpInterval() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        wekde::PlaylistManager mgr;
        mgr.setFilteredLibraryIntervalMin(10);
        QVERIFY(mgr.activate(wekde::kFilteredLibraryId));
        mgr.acceptPick("xyz"); // arms timer at 10min
        QCOMPARE(mgr.nextIntervalMsForTest(), 10 * 60 * 1000);

        // User edits SwitchTimer via dialog — in real flow that goes via
        // setFilteredLibraryIntervalMin from the ctrl. Simulate.
        mgr.setFilteredLibraryIntervalMin(45);
        mgr.reload(); // simulates "dialog persisted; runtime reloads"
        QCOMPARE(mgr.activePlaylistId(), wekde::kFilteredLibraryId);
        QCOMPARE(mgr.nextIntervalMsForTest(), 45 * 60 * 1000);
    }

    // reload in editorMode does NOT try to re-arm the timer — editor never
    // had one. Just re-pulls disk data for UI display.
    void reload_editorModeJustRefreshesData() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        setupConfigHome(d);
        QString id;
        {
            wekde::PlaylistManager initMgr;
            id = initMgr.createPlaylist("Z");
            initMgr.addItem(id, "A");
            initMgr.setIntervalMin(id, 5);
        }
        wekde::PlaylistManager editorMgr;
        editorMgr.setEditorMode(true);
        QCOMPARE(editorMgr.playlists().size(), 1);
        QCOMPARE(editorMgr.playlists().first().intervalMin, 5);

        // Out-of-band edit (simulating a second editor session writing
        // through the same XDG_CONFIG_HOME).
        {
            wekde::PlaylistManager otherMgr;
            otherMgr.setEditorMode(true);
            QVERIFY(otherMgr.setIntervalMin(id, 99));
        }
        editorMgr.reload();
        QCOMPARE(editorMgr.playlists().first().intervalMin, 99);
    }
};

QTEST_GUILESS_MAIN(TstPlaylistManager)
#include "tst_playlist_manager.moc"
