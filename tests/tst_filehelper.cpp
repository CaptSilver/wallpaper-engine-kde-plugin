// SPDX-License-Identifier: GPL-2.0-only
// Unit tests for wekde::FileHelper
//
// getDirSize behaviour note (depth > 0):
//   calcSize() starts at currentDepth=1 and recurses while currentDepth < depth,
//   so depth=N counts files up to N directory levels from the root.

#include <QtTest>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTemporaryFile>
#include <QVariantList>
#include <QVariantMap>

#include "FileHelper.hpp"

using namespace wekde;

class TestFileHelper : public QObject {
    Q_OBJECT

private:
    QTemporaryDir m_tmp;

    // Write `size` bytes to `filePath`; returns true on success.
    static bool writeBytes(const QString& filePath, int size, char fill = 'x') {
        QFile f(filePath);
        if (! f.open(QIODevice::WriteOnly)) return false;
        f.write(QByteArray(size, fill));
        return true;
    }

private slots:
    // ── test-suite setup / teardown ───────────────────────────────────────────
    void initTestCase() {
        // Redirect QStandardPaths to a safe test location so tests never
        // touch the real user config directory.
        QStandardPaths::setTestModeEnabled(true);
        QVERIFY2(m_tmp.isValid(), "Could not create temporary directory for tests");
    }

    void cleanupTestCase() {
        QString testCfg =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/wekde";
        QDir(testCfg).removeRecursively();
        QStandardPaths::setTestModeEnabled(false);
    }

    // ── readFile ──────────────────────────────────────────────────────────────
    void readFile_existingFile() {
        QTemporaryFile f(m_tmp.filePath("read_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("hello world");
        f.close();

        FileHelper helper;
        QCOMPARE(helper.readFile(f.fileName()), QByteArray("hello world"));
    }

    void readFile_nonExistentFile() {
        FileHelper helper;
        QByteArray result = helper.readFile("/tmp/wekde_test_nonexistent_file_xyz.txt");
        QVERIFY(result.isEmpty());
    }

    void readFile_emptyFile() {
        QTemporaryFile f(m_tmp.filePath("empty_XXXXXX"));
        QVERIFY(f.open());
        f.close(); // zero bytes

        FileHelper helper;
        QVERIFY(helper.readFile(f.fileName()).isEmpty());
    }

    void readFile_binaryContent() {
        QByteArray binary;
        for (int i = 0; i < 256; ++i) binary.append(static_cast<char>(i));

        QTemporaryFile f(m_tmp.filePath("bin_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write(binary);
        f.close();

        FileHelper helper;
        QCOMPARE(helper.readFile(f.fileName()), binary);
    }

    // ── readFile allowlist + size cap ────────────────────────────────────────

    void readFile_emptyAllowlist_isPermissiveByDefault() {
        // Back-compat: a default-installed plugin with no settings configured
        // has no roots seeded, so readFile keeps the pre-fix behaviour for
        // arbitrary paths. (Settings-configured users always seed at least
        // the cache root, so this branch only fires on first run.)
        QTemporaryFile f(m_tmp.filePath("perm_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("ok");
        f.close();
        FileHelper helper;
        QVERIFY(helper.readFile(f.fileName()).contains("ok"));
    }

    void readFile_pathInsideRoot_reads() {
        QTemporaryFile f(m_tmp.filePath("inside_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("inside");
        f.close();
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile(f.fileName()), QByteArray("inside"));
    }

    void readFile_pathOutsideRoot_returnsEmpty() {
        // /etc/hostname is universally readable on Linux — a clean witness
        // for "would have succeeded pre-fix; must be empty post-fix".
        if (! QFileInfo::exists("/etc/hostname"))
            QSKIP("no /etc/hostname witness on this system");
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QVERIFY(helper.readFile("/etc/hostname").isEmpty());
    }

#ifndef Q_OS_WIN
    void readFile_symlinkEscape_returnsEmpty() {
        // Symlink INSIDE an allowed root pointing OUTSIDE it must be refused
        // (canonical resolution defeats the trick). Reproduces the
        // "malicious workshop project.json -> ~/.ssh/id_rsa" case.
        if (! QFileInfo::exists("/etc/hostname"))
            QSKIP("no /etc/hostname witness on this system");
        const QString link = m_tmp.filePath("escape.link");
        QVERIFY(QFile::link("/etc/hostname", link));
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QVERIFY(helper.readFile(link).isEmpty());
    }

    void readFile_symlinkInsideRoot_reads() {
        // Internal symlink (root -> same root) is fine.
        QTemporaryFile target(m_tmp.filePath("tgt_XXXXXX"));
        target.setAutoRemove(false);
        QVERIFY(target.open());
        target.write("hop");
        target.close();
        const QString link = m_tmp.filePath("internal.link");
        QVERIFY(QFile::link(target.fileName(), link));
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile(link), QByteArray("hop"));
    }
#endif

    void readFile_dotDotEscape_returnsEmpty() {
        // .. traversal: addReadRoot points at a SUBDIR of m_tmp, then we
        // attempt a path that lexically contains `..` and canonicalises out.
        // The helper must check the canonical form, not the lexical one.
        if (! QFileInfo::exists("/etc/hostname"))
            QSKIP("no /etc/hostname witness on this system");
        QDir(m_tmp.path()).mkdir("sub");
        const QString rootSub = m_tmp.path() + "/sub";
        FileHelper    helper;
        helper.addReadRoot(rootSub);
        const QString escape = rootSub + "/../../../etc/hostname";
        QVERIFY(helper.readFile(escape).isEmpty());
    }

    void readFile_relativePath_normalizedAndChecked() {
        // CWD-relative paths must be canonicalised to absolute before the
        // allowlist check (QFileInfo::canonicalFilePath() resolves CWD too).
        QTemporaryFile f(m_tmp.filePath("rel_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("rel");
        f.close();
        const QString abs  = f.fileName();
        const QString base = QFileInfo(abs).fileName();
        const QString oldCwd = QDir::currentPath();
        QDir::setCurrent(m_tmp.path());
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile(base), QByteArray("rel"));
        QDir::setCurrent(oldCwd);
    }

    void readFile_oversize_returnsEmpty() {
        // 65 MiB > 64 MiB cap — even in permissive mode (no roots), the
        // cap fires. No need to actually allocate: write a sparse file via
        // QFile::resize.
        const QString big = m_tmp.filePath("big.bin");
        QFile         f(big);
        QVERIFY(f.open(QIODevice::WriteOnly));
        QVERIFY(f.resize(qint64(65) * 1024 * 1024));
        f.close();
        FileHelper helper;
        // Permissive (no roots) — cap still fires.
        QVERIFY(helper.readFile(big).isEmpty());
        // With an allowed root — still capped.
        helper.addReadRoot(m_tmp.path());
        QVERIFY(helper.readFile(big).isEmpty());
    }

    void readFile_normalSize_returnsBytes() {
        // 1 MiB < 64 MiB cap — must read.
        const QString small = m_tmp.filePath("small.bin");
        QVERIFY(writeBytes(small, 1 << 20));
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile(small).size(), qint64(1 << 20));
    }

    void addReadRoot_nonexistentPath_warnsAndNoOps() {
        FileHelper helper;
        helper.addReadRoot("/does/not/exist/zzz"); // canonical is empty -> reject
        // Add one real root so we are no longer permissive — then the
        // bogus path's absence is observable: a read of m_tmp succeeds, and
        // a read of /etc/hostname fails because the bogus path's empty
        // canonical didn't slip into the set.
        QTemporaryFile f(m_tmp.filePath("ne_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("x");
        f.close();
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile(f.fileName()), QByteArray("x"));
        if (QFileInfo::exists("/etc/hostname"))
            QVERIFY(helper.readFile("/etc/hostname").isEmpty());
    }

    void clearReadRoots_resetsToPermissive() {
        if (! QFileInfo::exists("/etc/hostname"))
            QSKIP("no /etc/hostname witness");
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QVERIFY(helper.readFile("/etc/hostname").isEmpty());     // gated
        helper.clearReadRoots();
        QVERIFY(! helper.readFile("/etc/hostname").isEmpty());   // permissive again
    }

    void readFile_rootExactMatch_reads() {
        // The root path itself (not a descendant) should also be accepted —
        // matches the `canon == root` branch of isUnderRoot. Verify by
        // adding a root equal to a file's canonical path (degenerate but
        // legal) and confirming readFile of that path returns the bytes.
        QTemporaryFile f(m_tmp.filePath("exact_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("e");
        f.close();
        FileHelper helper;
        helper.addReadRoot(QFileInfo(f.fileName()).canonicalFilePath());
        QCOMPARE(helper.readFile(f.fileName()), QByteArray("e"));
    }

    void addReadRoot_stripsFileUriPrefix() {
        // QML often passes paths through Common.urlNative which strips
        // file://, but the addReadRoot API also accepts the file:// form
        // directly (mirrors clearCacheDir's pre-canon strip). With the root
        // installed via file://, a native-path readFile of a file under
        // that root must still be accepted.
        QTemporaryFile f(m_tmp.filePath("uri_XXXXXX"));
        f.setAutoRemove(false);
        QVERIFY(f.open());
        f.write("uri");
        f.close();
        FileHelper helper;
        helper.addReadRoot("file://" + m_tmp.path()); // file:// stripped pre-canon
        QCOMPARE(helper.readFile(f.fileName()), QByteArray("uri"));
    }

    // ── getDirSize ────────────────────────────────────────────────────────────
    void getDirSize_nonExistentDir() {
        FileHelper helper;
        QCOMPARE(helper.getDirSize("/tmp/wekde_test_nonexistent_dir_xyz"), qint64(0));
    }

    void getDirSize_emptyDir() {
        QTemporaryDir d;
        FileHelper    helper;
        QCOMPARE(helper.getDirSize(d.path()), qint64(0));
    }

    void getDirSize_topLevelFiles_depth1() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("a.txt"), 100));
        QVERIFY(writeBytes(d.filePath("b.txt"), 150));

        FileHelper helper;
        QCOMPARE(helper.getDirSize(d.path(), 1), qint64(250));
    }

    void getDirSize_depth1_ignoresSubdirFiles() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("root.txt"), 100));
        QVERIFY(d.path().length() > 0);
        QDir(d.path()).mkdir("sub");
        QVERIFY(writeBytes(d.filePath("sub/sub.txt"), 200));

        FileHelper helper;
        // depth=1 → only root files counted
        QCOMPARE(helper.getDirSize(d.path(), 1), qint64(100));
    }

    void getDirSize_depth2_includesOneLevel() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("root.txt"), 100));
        QDir(d.path()).mkdir("sub");
        QVERIFY(writeBytes(d.filePath("sub/sub.txt"), 200));
        QDir(d.filePath("sub")).mkdir("subsub");
        QVERIFY(writeBytes(d.filePath("sub/subsub/deep.txt"), 300));

        FileHelper helper;
        // depth=2 → root + immediate subdir, NOT sub/subsub
        QCOMPARE(helper.getDirSize(d.path(), 2), qint64(300));
    }

    void getDirSize_depth3_includesTwoLevels() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("root.txt"), 100));
        QDir(d.path()).mkdir("sub");
        QVERIFY(writeBytes(d.filePath("sub/sub.txt"), 200));
        QDir(d.filePath("sub")).mkdir("subsub");
        QVERIFY(writeBytes(d.filePath("sub/subsub/deep.txt"), 300));

        FileHelper helper;
        // depth=3 (default) → root + sub + sub/subsub
        QCOMPARE(helper.getDirSize(d.path(), 3), qint64(600));
    }

    void getDirSize_unlimitedDepth() {
        QTemporaryDir d;
        // Create a 4-level-deep file (beyond default depth=3)
        QDir r(d.path());
        QVERIFY(r.mkpath("a/b/c/d"));
        QVERIFY(writeBytes(d.filePath("a/b/c/d/deep.txt"), 500));

        FileHelper helper;
        // depth=0 → unlimited; must find the file no matter how deep
        QCOMPARE(helper.getDirSize(d.path(), 0), qint64(500));
    }

    // Item 13: hidden (dotfile) bytes are counted. The old unlimited branch used
    // bare QDir::Files (which DOES include hidden files), so the unified walk must
    // keep counting them — locks the QDir::Hidden choice.
    void getDirSize_hiddenFilesCounted() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("visible.txt"), 100));
        QVERIFY(writeBytes(d.filePath(".hidden"), 40));
        FileHelper helper;
        QCOMPARE(helper.getDirSize(d.path(), 1), qint64(140)); // depth=1 incl. .hidden
    }

    // One unified depth-bounded path: a 3-level tree counts only up to `depth`.
    void getDirSize_depthBoundExcludesDeeper() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("root.txt"), 10));
        QDir(d.path()).mkdir("l1");
        QVERIFY(writeBytes(d.filePath("l1/a.txt"), 20));
        QDir(d.filePath("l1")).mkdir("l2");
        QVERIFY(writeBytes(d.filePath("l1/l2/b.txt"), 40));
        FileHelper helper;
        QCOMPARE(helper.getDirSize(d.path(), 1), qint64(10)); // only root.txt
        QCOMPARE(helper.getDirSize(d.path(), 2), qint64(30)); // root + l1
        QCOMPARE(helper.getDirSize(d.path(), 3), qint64(70)); // + l1/l2
    }

    // The async wrapper dispatches the walk off-thread and emits dirSizeReady on
    // the GUI thread. Proves async result == sync result and the emit is queued.
    void requestDirSize_emitsDirSizeReady() {
        QTemporaryDir d;
        QVERIFY(writeBytes(d.filePath("a.txt"), 100));
        QDir(d.path()).mkdir("sub");
        QVERIFY(writeBytes(d.filePath("sub/b.txt"), 50));

        FileHelper   helper;
        const qint64 expected = helper.getDirSize(d.path(), 3); // 150 (root + sub)

        QSignalSpy spy(&helper, &FileHelper::dirSizeReady);
        helper.requestDirSize(d.path(), 3);
        QCOMPARE(spy.count(), 0); // async: nothing emitted synchronously
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 5000);
        QCOMPARE(spy.at(0).at(0).toString(), d.path());
        QCOMPARE(spy.at(0).at(1).toLongLong(), expected);
    }

    // Plasma can destroy the FileHelper mid-walk on wallpaper switch. The
    // pool lambda used to touch instance-owned state (mutex + inflight set);
    // promoting that to a shared_ptr-managed sync block lets the lambda
    // outlive *this* without UAF on the unlock. We exercise the same pool +
    // QMetaObject::invokeMethod marshal pattern by destroying the helper
    // while requestDirSize is in flight. Silent on glibc without ASAN, but
    // pins the contract — turns red under ASAN/TSan.
    void destroy_during_async_dirSize_does_not_crash() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        QDir(d.path()).mkdir("sub");
        for (int i = 0; i < 200; ++i) {
            QVERIFY(writeBytes(d.filePath(QStringLiteral("sub/f%1.dat").arg(i)), 1024));
        }

        auto* helper = new FileHelper;
        helper->requestDirSize(d.path(), 0); // unlimited recursion
        QTest::qWait(0);                     // yield so the pool task actually starts
        delete helper;
        QCoreApplication::processEvents(); // drain any queued events targeting it
        QVERIFY(true);                     // no sanitizer trip, no hang
    }

    // ── getFolderList ─────────────────────────────────────────────────────────
    void getFolderList_nonExistentDirNoFallback() {
        FileHelper  helper;
        QVariantMap result = helper.getFolderList("/tmp/wekde_test_nodir_xyz");
        QVERIFY(result.isEmpty());
        // QML guard: empty map must not contain "items" — otherwise
        // `folder.items.forEach(...)` crashes because `!folder` is false
        // for truthy empty objects in JavaScript.
        QVERIFY(! result.contains("items"));
    }

    void getFolderList_nonExistentDirAllFallbacksMissing() {
        FileHelper  helper;
        QVariantMap opts;
        opts["fallbacks"]  = QStringList { "/tmp/wekde_no_dir_a", "/tmp/wekde_no_dir_b" };
        QVariantMap result = helper.getFolderList("/tmp/wekde_no_dir_c", opts);
        QVERIFY(result.isEmpty());
        QVERIFY(! result.contains("items"));
        QVERIFY(! result.contains("folder"));
    }

    void getFolderList_existingDir_returnsItems() {
        QTemporaryDir d;
        QDir(d.path()).mkdir("wallA");
        QDir(d.path()).mkdir("wallB");

        FileHelper  helper;
        QVariantMap result = helper.getFolderList(d.path());
        QVERIFY(! result.isEmpty());
        QCOMPARE(result["folder"].toString(), d.path());

        QVariantList items = result["items"].toList();
        QCOMPARE(items.size(), 2);

        // Each item must have "name" and numeric "mtime"
        for (const QVariant& v : items) {
            QVariantMap item = v.toMap();
            QVERIFY(item.contains("name"));
            QVERIFY(item.contains("mtime"));
            QVERIFY(item["mtime"].toLongLong() > 0);
        }
    }

    void getFolderList_fallbackUsedWhenPrimaryMissing() {
        QTemporaryDir d;
        QDir(d.path()).mkdir("fallback");

        FileHelper  helper;
        QVariantMap opts;
        opts["fallbacks"] = QStringList { d.filePath("fallback") };

        QVariantMap result = helper.getFolderList("/tmp/wekde_test_nodir_xyz", opts);
        QVERIFY(! result.isEmpty());
        QCOMPARE(result["folder"].toString(), d.filePath("fallback"));
    }

    void getFolderList_firstValidFallbackChosen() {
        QTemporaryDir d;
        QDir(d.path()).mkdir("second");

        FileHelper  helper;
        QVariantMap opts;
        // first fallback does not exist; second does
        opts["fallbacks"] = QStringList { "/tmp/wekde_no_such_dir_1", d.filePath("second") };

        QVariantMap result = helper.getFolderList("/tmp/wekde_no_such_dir_2", opts);
        QVERIFY(! result.isEmpty());
        QCOMPARE(result["folder"].toString(), d.filePath("second"));
    }

    void getFolderList_onlyDir_true_excludesFiles() {
        QTemporaryDir d;
        QDir(d.path()).mkdir("sub");
        QVERIFY(writeBytes(d.filePath("file.txt"), 1));

        FileHelper helper;
        // Default: only_dir=true
        QVariantMap  result = helper.getFolderList(d.path());
        QVariantList items  = result["items"].toList();
        QCOMPARE(items.size(), 1);
        QCOMPARE(items[0].toMap()["name"].toString(), QString("sub"));
    }

    void getFolderList_onlyDir_false_includesFiles() {
        QTemporaryDir d;
        QDir(d.path()).mkdir("sub");
        QVERIFY(writeBytes(d.filePath("file.txt"), 1));

        FileHelper  helper;
        QVariantMap opts;
        opts["only_dir"] = false;

        QVariantMap  result = helper.getFolderList(d.path(), opts);
        QVariantList items  = result["items"].toList();
        QCOMPARE(items.size(), 2);
    }

    void getFolderList_emptyDir_returnsEmptyItems() {
        QTemporaryDir d;
        FileHelper    helper;
        QVariantMap   result = helper.getFolderList(d.path());
        QVERIFY(! result.isEmpty());
        QVERIFY(result["items"].toList().isEmpty());
    }

    // ── wallpaper config round-trip ───────────────────────────────────────────
    void config_readNonExistent_returnsEmpty() {
        FileHelper helper;
        QVERIFY(helper.readWallpaperConfig("__no_such_wallpaper__").isEmpty());
    }

    void config_readCorruptJson_returnsEmpty() {
        // Write a file with invalid JSON directly into the config dir so that
        // readWallpaperConfig finds it but QJsonDocument::fromJson returns null.
        FileHelper    helper;
        const QString id = "test_corrupt";
        const QString path =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper/" + id + ".json";
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("not valid json {{{");
        f.close();

        QVERIFY(helper.readWallpaperConfig(id).isEmpty());

        QFile::remove(path);
    }

    void config_readUnopenable_returnsEmpty() {
        // file.exists() returns true but file.open(ReadOnly) fails — covers
        // the qWarning + return path in readWallpaperConfig (lines 200-203).
        // chmod 000 makes the file un-openable for the current user (when
        // not running as root, which is the test env).
        FileHelper    helper;
        const QString id = "test_unread";
        const QString path =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper/" + id + ".json";
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"({"key": "value"})");
        f.close();
        // Strip read perms.  On most filesystems this prevents open() unless
        // we're root — running as root is uncommon for `make test` so the
        // branch is exercised; if root for some reason, fall through and
        // skip rather than fail.
        QVERIFY(QFile::setPermissions(path, QFile::Permissions()));

        if (QFile(path).open(QIODevice::ReadOnly)) {
            // Running as root or filesystem ignores mode bits — restore and
            // skip rather than asserting a coverage path we can't reach.
            QFile::setPermissions(path, QFile::ReadUser | QFile::WriteUser);
            QFile::remove(path);
            QSKIP("filesystem permits read regardless of mode (likely running as root)");
        }

        QVariantMap got = helper.readWallpaperConfig(id);
        QVERIFY(got.isEmpty());

        // Restore so QFile::remove succeeds.
        QFile::setPermissions(path, QFile::ReadUser | QFile::WriteUser);
        QFile::remove(path);
    }

    void config_writeUnopenable_silentlyFails() {
        // file.open(WriteOnly) fails — covers the qWarning + early return in
        // writeWallpaperConfig (lines 227-229).  Make the wallpaper config
        // dir read-only so the inner QFile open() returns false.
        FileHelper    helper;
        const QString cfgDir =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        QDir().mkpath(cfgDir);
        const QString id   = "test_unwritable";
        const QString path = cfgDir + "/" + id + ".json";
        QFile::remove(path);

        // Lock the directory (no write/exec for owner) so the inner
        // QFile::open(WriteOnly) cannot create the file.  RAII guard
        // restores permissions even if a QVERIFY fails — without this,
        // the dir stays at 000 and every subsequent config_* test fails
        // with "FileHelper: Cannot write config".
        const QFile::Permissions origPerms = QFile(cfgDir).permissions();
        struct PermsGuard {
            QString            path;
            QFile::Permissions perms;
            bool               restored { false };
            ~PermsGuard() {
                if (! restored) QFile::setPermissions(path, perms);
            }
        } guard { cfgDir, origPerms, false };
        QVERIFY(QFile::setPermissions(cfgDir, QFile::ReadOwner | QFile::ReadUser));

        // Sanity-check the env actually disallowed writes (otherwise SKIP).
        {
            QFile probe(path);
            if (probe.open(QIODevice::WriteOnly)) {
                probe.close();
                QFile::remove(path);
                QSKIP("filesystem permits write regardless of mode (likely running as root)");
            }
        }

        // Now drive writeWallpaperConfig: should hit the qWarning + return.
        helper.writeWallpaperConfig(id, { { "x", 1 } });
        QVERIFY(! QFile::exists(path));

        // Restore permissions so cleanupTestCase can remove the dir.
        guard.restored = true;
        QFile::setPermissions(cfgDir, origPerms);
    }

    void config_writeAndRead_roundTrip() {
        FileHelper    helper;
        const QString id = "test_roundtrip";

        QVariantMap cfg;
        cfg["volume"] = 75;
        cfg["fps"]    = 30;
        cfg["mute"]   = false;
        helper.writeWallpaperConfig(id, cfg);

        QVariantMap got = helper.readWallpaperConfig(id);
        QCOMPARE(got["volume"].toInt(), 75);
        QCOMPARE(got["fps"].toInt(), 30);
        QCOMPARE(got["mute"].toBool(), false);

        helper.resetWallpaperConfig(id);
    }

    void config_write_mergesPreviousValues() {
        FileHelper    helper;
        const QString id = "test_merge";

        helper.writeWallpaperConfig(id, { { "volume", 50 }, { "fps", 60 } });

        // Partial update: only change volume
        helper.writeWallpaperConfig(id, { { "volume", 80 } });

        QVariantMap got = helper.readWallpaperConfig(id);
        QCOMPARE(got["volume"].toInt(), 80);
        QCOMPARE(got["fps"].toInt(), 60); // unchanged

        helper.resetWallpaperConfig(id);
    }

    void config_write_addsNewKey() {
        FileHelper    helper;
        const QString id = "test_newkey";

        helper.writeWallpaperConfig(id, { { "a", 1 } });
        helper.writeWallpaperConfig(id, { { "b", 2 } });

        QVariantMap got = helper.readWallpaperConfig(id);
        QCOMPARE(got["a"].toInt(), 1);
        QCOMPARE(got["b"].toInt(), 2);

        helper.resetWallpaperConfig(id);
    }

    void config_reset_removesConfig() {
        FileHelper    helper;
        const QString id = "test_reset";

        helper.writeWallpaperConfig(id, { { "key", "value" } });
        QVERIFY(! helper.readWallpaperConfig(id).isEmpty());

        helper.resetWallpaperConfig(id);
        QVERIFY(helper.readWallpaperConfig(id).isEmpty());
    }

    void config_reset_nonExistent_noError() {
        FileHelper helper;
        // Resetting a config that was never written must not crash or throw
        helper.resetWallpaperConfig("__never_existed__");
        QVERIFY(helper.readWallpaperConfig("__never_existed__").isEmpty());
    }

    void config_stringValues_preserved() {
        FileHelper    helper;
        const QString id = "test_strings";

        helper.writeWallpaperConfig(id, { { "name", "My Wallpaper" }, { "path", "/some/path" } });

        QVariantMap got = helper.readWallpaperConfig(id);
        QCOMPARE(got["name"].toString(), QString("My Wallpaper"));
        QCOMPARE(got["path"].toString(), QString("/some/path"));

        helper.resetWallpaperConfig(id);
    }

    // ── qwebChannelSource ────────────────────────────────────────────────────
    void qwebChannelSource_returnsStringOrEmpty() {
        // The bundled :/qtwebchannel/qwebchannel.js resource is compiled into
        // the test binary via tests/CMakeLists.txt → exercises the happy
        // path of qwebChannelSource (file open + readAll → fromUtf8).  If a
        // future build drops the qrc this test will catch it via the
        // non-empty assertion below.
        FileHelper helper;
        QString    out = helper.qwebChannelSource();
        QVERIFY2(! out.isEmpty(),
                 "qwebchannel.js Qt resource missing — line 57 happy path won't be covered");
        // Standard qwebchannel.js opens with a license / module comment.
        QVERIFY(out.contains("QWebChannel"));
    }

    void qwebChannelSource_missingResource_returnsEmpty() {
        // Unregister the qrc to drive the qWarning + return-empty branch
        // (lines 54-56 of FileHelper.cpp).  Re-register at end so subsequent
        // tests still see the resource.  AUTORCC exposes a
        // qCleanupResources_<basename>() / qInitResources_<basename>() pair.
        Q_CLEANUP_RESOURCE(qwebchannel);

        FileHelper helper;
        QString    out = helper.qwebChannelSource();
        QVERIFY(out.isEmpty());

        Q_INIT_RESOURCE(qwebchannel);
        // Sanity: re-init restores the resource for downstream tests.
        QVERIFY(! helper.qwebChannelSource().isEmpty());
    }

    // ── patchedHtml ──────────────────────────────────────────────────────────
    void patchedHtml_injectsAfterHead() {
        QString path = m_tmp.filePath("test.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<html><head><title>Test</title></head><body></body></html>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);
        // Script must appear right after <head>
        int headIdx   = result.indexOf("<head>");
        int scriptIdx = result.indexOf("<script>", headIdx);
        QCOMPARE(scriptIdx, headIdx + 6);
        // Must contain the History API patch
        QVERIFY(result.contains("history.replaceState"));
        QVERIFY(result.contains("history.pushState"));
        // Original content preserved
        QVERIFY(result.contains("<title>Test</title>"));
        QVERIFY(result.contains("<body></body>"));
    }

    void patchedHtml_caseInsensitiveHead() {
        QString path = m_tmp.filePath("upper.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<HTML><HEAD><TITLE>Upper</TITLE></HEAD><BODY></BODY></HTML>");
        f.close();

        FileHelper helper;
        QString    result    = helper.patchedHtml(path);
        int        headIdx   = result.indexOf("<HEAD>");
        int        scriptIdx = result.indexOf("<script>", headIdx);
        QCOMPARE(scriptIdx, headIdx + 6);
    }

    void patchedHtml_noHeadTag_prepends() {
        QString path = m_tmp.filePath("nohead.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<body>Hello</body>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);
        // Script prepended at the start
        QVERIFY(result.startsWith("<script>"));
        QVERIFY(result.contains("<body>Hello</body>"));
    }

    void patchedHtml_nonExistentFile_returnsEmpty() {
        FileHelper helper;
        QString    result = helper.patchedHtml("/tmp/wekde_nonexistent.html");
        QVERIFY(result.isEmpty());
    }

    void patchedHtml_containsErrorHandlers() {
        QString path = m_tmp.filePath("errhandler.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<html><head></head></html>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);
        QVERIFY(result.contains("window.addEventListener('error'"));
        QVERIFY(result.contains("unhandledrejection"));
        QVERIFY(result.contains("SecurityError"));
    }

    // ── Item 16: adversarial patchedHtml head injection ───────────────────────
    // Attributed <head> (Angular/framework scaffolds — the very pages the
    // SecurityError shim targets). The literal "<head>" is absent, so the old
    // code prepended BEFORE <!DOCTYPE> → quirks mode. The shim must land after
    // the '>' of <head lang="en"> and the doctype must still be first.
    void patchedHtml_attributedHead_insertsInsideHead() {
        QString path = m_tmp.filePath("attrhead.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<!DOCTYPE html><html><head lang=\"en\"><title>x</title></head>"
                "<body></body></html>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);

        // Doctype is still first → no quirks mode.
        QVERIFY(result.startsWith("<!DOCTYPE html>"));
        const int doctypeIdx = result.indexOf("<!DOCTYPE html>");
        const int headTagIdx = result.indexOf("<head lang=\"en\">");
        const int headClose  = headTagIdx + QString("<head lang=\"en\">").length();
        const int scriptIdx  = result.indexOf("<script>");
        // Script is after the doctype...
        QVERIFY(scriptIdx > doctypeIdx);
        // ...and exactly after the '>' of the attributed head tag.
        QCOMPARE(scriptIdx, headClose);
        // <title> (the head's own content) comes AFTER the injected script.
        QVERIFY(result.indexOf("<title>x</title>") > scriptIdx);
        QVERIFY(result.contains("history.replaceState"));
    }

    // A <head> inside a comment is a decoy; the shim must land in the REAL head.
    void patchedHtml_headInComment_skipsDecoy() {
        QString path = m_tmp.filePath("commenthead.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<!DOCTYPE html><!-- <head> --><html><head><title>real</title></head>"
                "<body></body></html>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);
        // The decoy "<head>" is inside the comment; the real one is after <html>.
        const int commentEnd = result.indexOf("-->");
        const int scriptIdx  = result.indexOf("<script>");
        QVERIFY(scriptIdx > commentEnd); // shim is past the comment, in the real head
        // And it precedes the real head's <title>.
        QVERIFY(result.indexOf("<title>real</title>") > scriptIdx);
    }

    // <header> (and <heading>) must NOT match the <head start-tag scan; with no
    // real <head>, fall back after <html>/doctype (never before the doctype).
    void patchedHtml_headerTag_notMatched() {
        QString path = m_tmp.filePath("headertag.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<!DOCTYPE html><html><body><header>nav</header></body></html>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);
        QVERIFY(result.startsWith("<!DOCTYPE html>")); // doctype still first
        const int htmlIdx   = result.indexOf("<html>");
        const int scriptIdx = result.indexOf("<script>");
        const int headerIdx = result.indexOf("<header>");
        // Fell back to just after <html>, NOT into/at <header>.
        QCOMPARE(scriptIdx, htmlIdx + QString("<html>").length());
        QVERIFY(scriptIdx < headerIdx);
    }

    // No <head> at all, but a doctype present → insert after the doctype,
    // never before it.
    void patchedHtml_noHeadButDoctype_insertsAfterDoctype() {
        QString path = m_tmp.filePath("nohead_doctype.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        // No <html> tag either, so the fallback must use the doctype.
        f.write("<!DOCTYPE html><body>hi</body>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);
        QVERIFY(result.startsWith("<!DOCTYPE html>"));
        const int doctypeEnd =
            result.indexOf("<!DOCTYPE html>") + QString("<!DOCTYPE html>").length();
        QCOMPARE(result.indexOf("<script>"), doctypeEnd);
    }

    // ── readActiveBindings ───────────────────────────────────────────────────
    void bindings_readNonExistent_returnsEmpty() {
        FileHelper helper;
        QVERIFY(helper.readActiveBindings("__no_such_id__").isEmpty());
    }

    void bindings_readValidArray() {
        FileHelper    helper;
        const QString id = "test_bindings";
        const QString path =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper/" + id + "_bindings.json";
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"(["volume","speed","color"])");
        f.close();

        QVariantList result = helper.readActiveBindings(id);
        QCOMPARE(result.size(), 3);
        QCOMPARE(result[0].toString(), QString("volume"));
        QCOMPARE(result[1].toString(), QString("speed"));
        QCOMPARE(result[2].toString(), QString("color"));

        QFile::remove(path);
    }

    void bindings_readCorruptJson_returnsEmpty() {
        FileHelper    helper;
        const QString id = "test_bindings_corrupt";
        const QString path =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper/" + id + "_bindings.json";
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("{not an array}");
        f.close();

        QVERIFY(helper.readActiveBindings(id).isEmpty());

        QFile::remove(path);
    }

    void bindings_readObjectNotArray_returnsEmpty() {
        FileHelper    helper;
        const QString id = "test_bindings_object";
        const QString path =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper/" + id + "_bindings.json";
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"({"key": "value"})");
        f.close();

        QVERIFY(helper.readActiveBindings(id).isEmpty());

        QFile::remove(path);
    }

    // ── scanVideoFolder ──────────────────────────────────────────────────────
    void scanVideoFolder_emptyDirReturnsEmpty() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(d.path());
        QCOMPARE(result.size(), 0);
    }

    void scanVideoFolder_filtersByExtensionAllowlist() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        QFile::copy("/dev/null", d.filePath("a.mp4"));
        QFile::copy("/dev/null", d.filePath("b.MKV")); // case-insensitive
        QFile::copy("/dev/null", d.filePath("c.txt")); // excluded
        QFile::copy("/dev/null", d.filePath("d.jpg")); // excluded
        QFile::copy("/dev/null", d.filePath("e.webm"));

        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(d.path());
        QCOMPARE(result.size(), 3);
        QStringList names;
        for (const auto& v : result) names << v.toMap().value("name").toString();
        QVERIFY(names.contains("a.mp4"));
        QVERIFY(names.contains("b.MKV"));
        QVERIFY(names.contains("e.webm"));
        QVERIFY(! names.contains("c.txt"));
    }

    void scanVideoFolder_recurses() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        QDir(d.path()).mkpath("nested/deep");
        QFile::copy("/dev/null", d.filePath("top.mp4"));
        QFile::copy("/dev/null", d.filePath("nested/mid.mkv"));
        QFile::copy("/dev/null", d.filePath("nested/deep/bottom.webm"));

        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(d.path());
        QCOMPARE(result.size(), 3);
    }

    void scanVideoFolder_returnsAbsolutePathAndMtime() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        QFile f(d.filePath("x.mp4"));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("a");
        f.close();

        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(d.path());
        QCOMPARE(result.size(), 1);
        auto m = result.first().toMap();
        QCOMPARE(m.value("name").toString(), QStringLiteral("x.mp4"));
        QVERIFY(m.value("path").toString().endsWith("/x.mp4"));
        QVERIFY(QFileInfo(m.value("path").toString()).isAbsolute());
        QVERIFY(m.value("mtime").toLongLong() > 0);
        QVERIFY(m.value("size").toLongLong() >= 1);
    }

    void scanVideoFolder_nonexistentReturnsEmpty() {
        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder("/tmp/wekde_nonexistent_xyz");
        QCOMPARE(result.size(), 0);
    }

#ifndef Q_OS_WIN
    // A self-referential symlink (dir/loop -> dir) under FollowSymlinks must
    // NOT cause an infinite walk — Qt's QDirIterator tracks visited canonical
    // paths and terminates. PASSING == termination (a regression hangs; the
    // suite has a TIMEOUT so it fails loudly). The real video is listed once.
    void scanVideoFolder_symlinkLoopTerminates() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        QFile vid(d.filePath("real.mp4"));
        QVERIFY(vid.open(QIODevice::WriteOnly));
        vid.write("v");
        vid.close();
        // dir/loop -> dir  (a cycle for a FollowSymlinks walker).
        QVERIFY(QFile::link(d.path(), d.filePath("loop")));

        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(d.path());
        // Exactly one entry — the real video, not re-counted through the loop.
        QCOMPARE(result.size(), 1);
        QCOMPARE(result.first().toMap().value("name").toString(), QStringLiteral("real.mp4"));
    }

    // A directory symlink inside the chosen folder that points at an OUTSIDE
    // directory IS followed: users curate ~/Videos with symlinks into the WE
    // workshop tree and onto external storage. The outside video appears in
    // the listing.
    void scanVideoFolder_followsDirSymlinkOutsideFolder() {
        QTemporaryDir inside, outside;
        QVERIFY(inside.isValid());
        QVERIFY(outside.isValid());
        QFile out(outside.filePath("external.mp4"));
        QVERIFY(out.open(QIODevice::WriteOnly));
        out.write("x");
        out.close();
        // inside/escape -> outside
        QVERIFY(QFile::link(outside.path(), inside.filePath("escape")));

        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(inside.path());
        QCOMPARE(result.size(), 1);
        QCOMPARE(result.first().toMap().value("name").toString(), QStringLiteral("external.mp4"));
    }

    // A FILE symlink inside the chosen folder pointing at an OUTSIDE video
    // file is listed under its link name. (mpv resolves the symlink itself
    // when opening, so playback works.)
    void scanVideoFolder_followsFileSymlinkOutsideFolder() {
        QTemporaryDir inside, outside;
        QVERIFY(inside.isValid());
        QVERIFY(outside.isValid());
        QFile real(outside.filePath("real.mp4"));
        QVERIFY(real.open(QIODevice::WriteOnly));
        real.write("v");
        real.close();
        // inside/link.mp4 -> outside/real.mp4
        QVERIFY(QFile::link(outside.filePath("real.mp4"), inside.filePath("link.mp4")));

        FileHelper   helper;
        QVariantList result = helper.scanVideoFolder(inside.path());
        QCOMPARE(result.size(), 1);
        QCOMPARE(result.first().toMap().value("name").toString(), QStringLiteral("link.mp4"));
        // Path the QML side feeds to mpv must be a real, readable file once
        // the symlink is resolved.
        const QString p = result.first().toMap().value("path").toString();
        QFileInfo     fi(p);
        QVERIFY(fi.exists());
        QCOMPARE(fi.canonicalFilePath(),
                 QFileInfo(outside.filePath("real.mp4")).canonicalFilePath());
    }
#endif

    // ── atomicWriteJson ───────────────────────────────────────────────────────
    void atomicWriteJson_writesAndIsReReadable() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = d.path() + "/data.json";

        QJsonObject obj;
        obj["k"] = QString("v");
        obj["n"] = 7;

        FileHelper fh;
        QVERIFY(fh.atomicWriteJson(path, QJsonDocument(obj)));

        QFile f(path);
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QJsonDocument back = QJsonDocument::fromJson(f.readAll());
        QVERIFY(back.isObject());
        QCOMPARE(back.object().value("k").toString(), QString("v"));
        QCOMPARE(back.object().value("n").toInt(), 7);

        // The .tmp sibling must not linger.
        QVERIFY(! QFileInfo::exists(path + ".tmp"));
    }

    void atomicWriteJson_replacesExisting() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = d.path() + "/data.json";

        QFile pre(path);
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write("garbage");
        pre.close();

        FileHelper  fh;
        QJsonObject obj;
        obj["v"] = 1;
        QVERIFY(fh.atomicWriteJson(path, QJsonDocument(obj)));

        QFile f(path);
        QVERIFY(f.open(QIODevice::ReadOnly));
        const auto bytes = f.readAll();
        QVERIFY(! bytes.contains("garbage"));
    }

    void atomicWriteJson_failsOnUnwritablePath() {
        FileHelper  fh;
        QJsonObject obj;
        obj["v"] = 1;
        // /nonexistent-dir-... cannot be created or written to.
        const bool ok =
            fh.atomicWriteJson("/nonexistent-test-dir-xyz/data.json", QJsonDocument(obj));
        QCOMPARE(ok, false);
    }

    // ── clearCacheDir — safety belt + recursive removal contract ───────────
    // The function refuses any path outside QStandardPaths::CacheLocation.
    // Without this guard a misconfigured plugin_info.cache_path could
    // wipe arbitrary directories.

    void clearCacheDir_emptyPathReturnsFalse() {
        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(""), false);
    }

    void clearCacheDir_refusesPathOutsideCacheRoot() {
        FileHelper    fh;
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString outside = d.path();
        QVERIFY(QFileInfo(outside).exists());
        QCOMPARE(fh.clearCacheDir(outside), false);
        // Post-condition: dir still exists.
        QVERIFY(QFileInfo(outside).exists());
    }

    // Helper — return whatever the real CacheLocation root canonicalizes
    // to. The safety belt canonicalizes both sides, so the test target
    // must live UNDER the real cache root (Qt appends the application
    // name to XDG_CACHE_HOME). mkpath the raw path first so the
    // canonicalization step succeeds.
    static QString cacheRootCanonical() {
        const QString raw = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
        if (raw.isEmpty()) return QString();
        QDir().mkpath(raw);
        return QFileInfo(raw).canonicalFilePath();
    }

    void clearCacheDir_acceptsPathInsideCacheRoot() {
        const QString root = cacheRootCanonical();
        QDir().mkpath(root); // ensure the cache root exists for canonicalization
        const QString target = root + "/wek-test-clear";
        QDir().mkpath(target);
        QDir().mkpath(target + "/sub1");
        QFile a(target + "/sub1/file.txt");
        QVERIFY(a.open(QIODevice::WriteOnly));
        a.write("data");
        a.close();
        QFile b(target + "/top.txt");
        QVERIFY(b.open(QIODevice::WriteOnly));
        b.write("data");
        b.close();

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(target), true);
        // Directory itself stays (so bindings to it remain valid),
        // contents are gone.
        QVERIFY(QFileInfo(target).exists());
        QCOMPARE(
            QDir(target).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden).size(),
            0);
        // Clean up
        QDir(target).removeRecursively();
    }

    void clearCacheDir_nonexistentPathReturnsTrue() {
        const QString root = cacheRootCanonical();
        QDir().mkpath(root);
        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(root + "/never-existed"), true);
    }

    void clearCacheDir_stripsFileURIPrefix() {
        const QString root = cacheRootCanonical();
        QDir().mkpath(root);
        const QString target = root + "/file-uri-test";
        QDir().mkpath(target);
        FileHelper fh;
        QCOMPARE(fh.clearCacheDir("file://" + target), true);
        QDir(target).removeRecursively();
    }

    // Regression (F15): a sibling directory whose name merely *prefixes* the
    // cache root (e.g. ".../<cacheRoot>-sibling") must be refused. A bare
    // QString::startsWith(cacheRoot) belt would accept it and recursively
    // delete its contents — data loss outside the cache. The fix requires an
    // exact match or a child separated by '/'.
    void clearCacheDir_refusesSiblingPrefixOfCacheRoot() {
        const QString root = cacheRootCanonical();
        QVERIFY(! root.isEmpty());
        // A real dir OUTSIDE the canonical root but sharing its name prefix.
        const QString sibling = root + "-sibling";
        QDir().mkpath(sibling);
        QVERIFY(QFileInfo(sibling).exists());
        const QString victim = sibling + "/keep-me.txt";
        QFile         f(victim);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("must survive");
        f.close();

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(sibling), false);
        // The belt must not have deleted anything in the sibling.
        QVERIFY(QFileInfo(victim).exists());

        // Clean up.
        QDir(sibling).removeRecursively();
    }

    // The exact-match arm of the F15 predicate must remain reachable: the
    // cache root itself is the live binding target (plugin_info.cache_path)
    // and clearing its own contents is the normal case.
    void clearCacheDir_acceptsCacheRootItself() {
        const QString root = cacheRootCanonical();
        QVERIFY(! root.isEmpty());
        QDir().mkpath(root);
        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(root), true);
        // Directory itself stays valid (contents-only clear).
        QVERIFY(QFileInfo(root).exists());
    }

#ifndef Q_OS_WIN
    // Item 18 HEADLINE data-loss regression: a directory symlink INSIDE the cache
    // that points OUTSIDE must be unlinked as a link only — clearCacheDir must NOT
    // recurse through it and delete the target's contents.
    void clearCacheDir_doesNotDeleteThroughEscapingDirSymlink() {
        const QString root = cacheRootCanonical();
        QVERIFY(! root.isEmpty());
        const QString target = root + "/wek-test-escape";
        QDir().mkpath(target);

        // Outside dir (NOT under the cache root) holding a file that must survive.
        QTemporaryDir outside;
        QVERIFY(outside.isValid());
        QFile keep(outside.filePath("keep-me.txt"));
        QVERIFY(keep.open(QIODevice::WriteOnly));
        keep.write("must survive");
        keep.close();

        // <target>/escape -> <outside>  (a directory symlink escaping the cache)
        const QString link = target + "/escape";
        QVERIFY(QFile::link(outside.path(), link));

        FileHelper fh;
        // Spec decision: an escaping directory symlink is a hard failure
        // (qWarning + return false) — surface the misconfiguration loudly.
        QCOMPARE(fh.clearCacheDir(target), false);

        // The outside dir + its file survive; only the link's existence matters.
        QVERIFY(QFileInfo(outside.filePath("keep-me.txt")).exists());
        QVERIFY(QDir(outside.path()).exists());

        QDir(target).removeRecursively();
    }

    // A plain (file) symlink inside the cache pointing outside is removed as a
    // link only; the outside file survives. This branch succeeds (no escape via
    // recursion is possible for a file symlink).
    void clearCacheDir_removesPlainSymlinkFileWithoutTarget() {
        const QString root = cacheRootCanonical();
        QVERIFY(! root.isEmpty());
        const QString target = root + "/wek-test-filelink";
        QDir().mkpath(target);

        QTemporaryDir outside;
        QVERIFY(outside.isValid());
        QFile ext(outside.filePath("external.txt"));
        QVERIFY(ext.open(QIODevice::WriteOnly));
        ext.write("survive");
        ext.close();

        const QString link = target + "/lnk";
        QVERIFY(QFile::link(outside.filePath("external.txt"), link));

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(target), true);
        // The link is gone; the outside file survives.
        QVERIFY(! QFileInfo(link).isSymLink());
        QVERIFY(! QFileInfo::exists(link));
        QVERIFY(QFileInfo(outside.filePath("external.txt")).exists());

        QDir(target).removeRecursively();
    }
#endif

    // ── writeWallpaperConfig nested QVariantMap round-trip ─────────────────
    // SceneScript user properties are arbitrary JSON objects; the config
    // path needs to preserve the structure across write→read without
    // flattening or losing nested objects.
    void writeWallpaperConfig_nestedQVariantMapRoundTrips() {
        QTemporaryDir cfgRoot;
        QVERIFY(cfgRoot.isValid());
        qputenv("XDG_CONFIG_HOME", cfgRoot.path().toLocal8Bit());
        FileHelper  fh;
        QVariantMap deep;
        QVariantMap inner;
        inner["alpha"] = 0.42;
        inner["beta"]  = QVariantList { "one", "two", 3 };
        deep["nested"] = inner;
        deep["top"]    = "string value";
        deep["scalar"] = 7;

        QVariantMap topLevel;
        topLevel["user_props"] = deep;
        fh.writeWallpaperConfig("12345", topLevel);

        const auto read = fh.readWallpaperConfig("12345");
        QVERIFY(read.contains("user_props"));
        const QVariantMap readUserProps = read.value("user_props").toMap();
        QCOMPARE(readUserProps.value("top").toString(), QString("string value"));
        QCOMPARE(readUserProps.value("scalar").toInt(), 7);
        const QVariantMap readInner = readUserProps.value("nested").toMap();
        QCOMPARE(readInner.value("alpha").toDouble(), 0.42);
        QCOMPARE(readInner.value("beta").toList().size(), 3);
    }

    // F17: writeWallpaperConfig now routes through atomicWriteJson
    // (write-tmp-then-rename) so a crash/full-disk can't truncate the live
    // config. Observable proof the atomic path ran: no <file>.tmp lingers
    // after a successful write, and the data round-trips.
    void writeWallpaperConfig_atomicLeavesNoTmpAndRoundTrips() {
        FileHelper fh;

        QVariantMap m;
        m["foo"] = "bar";
        m["n"]   = 11;
        fh.writeWallpaperConfig("atomic-id", m);

        const auto read = fh.readWallpaperConfig("atomic-id");
        QCOMPARE(read.value("foo").toString(), QString("bar"));
        QCOMPARE(read.value("n").toInt(), 11);

        // Recompute the config file path exactly as FileHelper does. Under
        // QStandardPaths::setTestModeEnabled (initTestCase), GenericConfigLocation
        // resolves to the test sandbox and ignores XDG_CONFIG_HOME.
        const QString cfgFile =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper/atomic-id.json";
        QVERIFY(QFileInfo::exists(cfgFile)); // sanity: write landed here
        // The .tmp sibling must not linger — its presence would mean the
        // atomic rename step never ran.
        QVERIFY(! QFileInfo::exists(cfgFile + ".tmp"));
    }

    // F17: an unwritable target must NOT leave a truncated stub OR an orphan
    // <file>.tmp. Pre-fix, the raw WriteOnly open (no Truncate, unchecked
    // write) could create/clobber the file; post-fix, atomicWriteJson writes
    // to <file>.tmp first, checks the result, and removes the tmp on failure,
    // never touching the real path. Mirrors config_writeUnopenable_silentlyFails
    // (lock the real test-mode config dir read-only) and adds the .tmp check
    // that is specific to the atomic path. writeWallpaperConfig is void →
    // assert via existence.
    void writeWallpaperConfig_failureLeavesNoPartialNorTmp() {
        FileHelper    helper;
        const QString cfgDir =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        QDir().mkpath(cfgDir);
        const QString id   = "test_atomic_fail";
        const QString path = cfgDir + "/" + id + ".json";
        QFile::remove(path);
        QFile::remove(path + ".tmp");

        // Lock the directory read-only so the inner QFile open (of the .tmp)
        // cannot create the file. RAII guard restores perms even on a failed
        // QVERIFY so subsequent tests aren't poisoned.
        const QFile::Permissions origPerms = QFile(cfgDir).permissions();
        struct PermsGuard {
            QString            path;
            QFile::Permissions perms;
            bool               restored { false };
            ~PermsGuard() {
                if (! restored) QFile::setPermissions(path, perms);
            }
        } guard { cfgDir, origPerms, false };
        QVERIFY(QFile::setPermissions(cfgDir, QFile::ReadOwner | QFile::ReadUser));

        // Sanity: confirm the env actually disallowed writes (else SKIP).
        {
            QFile probe(path + ".tmp");
            if (probe.open(QIODevice::WriteOnly)) {
                probe.close();
                QFile::remove(path + ".tmp");
                QSKIP("filesystem permits write regardless of mode (likely running as root)");
            }
        }

        helper.writeWallpaperConfig(id, { { "x", 1 } }); // void; must not crash
        QVERIFY(! QFile::exists(path));                  // no truncated stub
        QVERIFY(! QFile::exists(path + ".tmp"));         // tmp removed on failure

        guard.restored = true;
        QFile::setPermissions(cfgDir, origPerms);
    }
};

QTEST_MAIN(TestFileHelper)
#include "tst_filehelper.moc"
