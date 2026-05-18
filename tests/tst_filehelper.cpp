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
        FileHelper fh;
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
        const QString raw = QStandardPaths::writableLocation(
                                QStandardPaths::CacheLocation);
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
        QCOMPARE(QDir(target).entryList(QDir::AllEntries | QDir::NoDotAndDotDot
                                       | QDir::Hidden).size(),
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

    // ── writeWallpaperConfig nested QVariantMap round-trip ─────────────────
    // SceneScript user properties are arbitrary JSON objects; the config
    // path needs to preserve the structure across write→read without
    // flattening or losing nested objects.
    void writeWallpaperConfig_nestedQVariantMapRoundTrips() {
        QTemporaryDir cfgRoot;
        QVERIFY(cfgRoot.isValid());
        qputenv("XDG_CONFIG_HOME", cfgRoot.path().toLocal8Bit());
        FileHelper fh;
        QVariantMap deep;
        QVariantMap inner;
        inner["alpha"] = 0.42;
        inner["beta"]  = QVariantList{ "one", "two", 3 };
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
};

QTEST_MAIN(TestFileHelper)
#include "tst_filehelper.moc"
