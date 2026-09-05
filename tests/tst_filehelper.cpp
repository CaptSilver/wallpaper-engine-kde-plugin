// SPDX-License-Identifier: GPL-2.0-only
// Unit tests for wekde::FileHelper
//
// getDirSize behaviour note (depth > 0):
//   calcSize() starts at currentDepth=1 and recurses while currentDepth < depth,
//   so depth=N counts files up to N directory levels from the root.

#include <QtTest>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTemporaryFile>
#include <QThread>
#include <QVariantList>
#include <QVariantMap>

#include <atomic>
#include <thread>

#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "CachePaths.hpp"
#include "FileHelper.hpp"
#include "TestSandbox.h"

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

    // Read offset of whatever fd this process holds on `path`, or -1 when the
    // file is not open. A non-zero offset proves the reader is past its size
    // check and inside the chunk loop, which is the only window in which
    // growing the file exercises the mid-read cap. Matching on (dev, ino)
    // rather than on the readlink text keeps it right when the sandbox path
    // runs through a symlink.
    static qint64 openReadOffset(const QString& path) {
        struct stat want {};
        if (::stat(QFile::encodeName(path).constData(), &want) != 0) return -1;
        DIR* dir = ::opendir("/proc/self/fd");
        if (dir == nullptr) return -1;
        qint64 pos = -1;
        while (struct dirent* ent = ::readdir(dir)) {
            if (ent->d_name[0] == '.') continue;
            const QByteArray link = QByteArray("/proc/self/fd/") + ent->d_name;
            struct stat      got {};
            if (::stat(link.constData(), &got) != 0) continue;
            if (got.st_dev != want.st_dev || got.st_ino != want.st_ino) continue;
            QFile info(QStringLiteral("/proc/self/fdinfo/") + QString::fromLatin1(ent->d_name));
            if (! info.open(QIODevice::ReadOnly)) continue;
            const QList<QByteArray> lines = info.readAll().split('\n');
            for (const QByteArray& line : lines)
                if (line.startsWith("pos:")) pos = qMax(pos, line.mid(4).trimmed().toLongLong());
        }
        ::closedir(dir);
        return pos;
    }

    // Fill `dir` with empty files until one synchronous getDirSize walk costs at
    // least `minMs`. Used to park every pool thread inside a long job so a later
    // dispatch is provably still queued. A hard-coded file count would quietly
    // stop being slow enough on a faster box and turn a deterministic test into
    // a coin flip; this calibrates against the machine it runs on. Returns false
    // if the entry cap is hit without getting slow enough, so the caller skips
    // rather than proceeding on a broken assumption.
    static bool makeSlowWalkDir(FileHelper& helper, const QString& dir, int minMs) {
        int made = 0;
        while (made < 40000) {
            for (int i = 0; i < 4000; ++i, ++made) {
                QFile f(dir + QStringLiteral("/e%1").arg(made));
                if (! f.open(QIODevice::WriteOnly)) return false;
            }
            QElapsedTimer t;
            t.start();
            helper.getDirSize(dir, 0); // synchronous — runs here, not on the pool
            if (t.elapsed() >= minMs) return true;
        }
        return false;
    }

private slots:
    // ── test-suite setup / teardown ───────────────────────────────────────────
    void initTestCase() {
        // Per-process isolated HOME so QStandardPaths::setTestModeEnabled's
        // ~/.qttest/ sandbox is unique per parallel Mull mutant invocation.
        wek::test_sandbox::enableIsolated();
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
        if (! QFileInfo::exists("/etc/hostname")) QSKIP("no /etc/hostname witness on this system");
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QVERIFY(helper.readFile("/etc/hostname").isEmpty());
    }

#ifndef Q_OS_WIN
    void readFile_symlinkEscape_returnsEmpty() {
        // Symlink INSIDE an allowed root pointing OUTSIDE it must be refused
        // (canonical resolution defeats the trick). Reproduces the
        // "malicious workshop project.json -> ~/.ssh/id_rsa" case.
        if (! QFileInfo::exists("/etc/hostname")) QSKIP("no /etc/hostname witness on this system");
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
        if (! QFileInfo::exists("/etc/hostname")) QSKIP("no /etc/hostname witness on this system");
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
        const QString abs    = f.fileName();
        const QString base   = QFileInfo(abs).fileName();
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

    void readFile_atTheCapIsRead_oneByteOverIsRefused() {
        // The cap is inclusive. A file measuring exactly kMaxReadSize is still
        // handed back; the refusal starts at the very next byte. Sparse files
        // via QFile::resize, so neither one costs 64 MiB of disk.
        const QString atCap = m_tmp.filePath("atcap.bin");
        const QString over  = m_tmp.filePath("overcap.bin");
        {
            QFile f(atCap);
            QVERIFY(f.open(QIODevice::WriteOnly));
            QVERIFY(f.resize(FileHelper::kMaxReadSize));
        }
        {
            QFile f(over);
            QVERIFY(f.open(QIODevice::WriteOnly));
            QVERIFY(f.resize(FileHelper::kMaxReadSize + 1));
        }

        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile(atCap).size(), qint64(FileHelper::kMaxReadSize));
        QTest::ignoreMessage(QtWarningMsg, QRegularExpression("refused over-size file"));
        QVERIFY(helper.readFile(over).isEmpty());
    }

    void readFile_fileThatGrowsPastTheCapMidRead_isRefused() {
        // st_size is a hint, not a promise: a wallpaper's file can be appended
        // to after the size check and before the last chunk arrives. A file
        // sitting exactly on the cap when it is opened, plus one byte added
        // while it is being drained, is over the cap by the time the bytes
        // land, and the chunk loop is the only thing that can notice.
        const QString path = m_tmp.filePath("growing.bin");
        {
            QFile f(path);
            QVERIFY(f.open(QIODevice::WriteOnly));
            QVERIFY(f.resize(FileHelper::kMaxReadSize)); // sparse
        }

        std::atomic<bool> stop { false };
        std::atomic<bool> grew { false };
        // Wait for the read offset to move before appending: a byte added
        // before the size check would trip the up-front cap instead, which is
        // a different branch and would leave this one unexercised.
        std::thread grower([&] {
            QElapsedTimer t;
            t.start();
            while (! stop.load(std::memory_order_relaxed) && t.elapsed() < 10000) {
                if (openReadOffset(path) <= 0) continue;
                QFile g(path);
                if (g.open(QIODevice::Append) && g.write("x", 1) == 1) grew.store(true);
                return;
            }
        });

        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QTest::ignoreMessage(QtWarningMsg, QRegularExpression("refused file that grew past"));
        const QByteArray got = helper.readFile(path);
        stop.store(true);
        grower.join();

        QVERIFY2(grew.load(), "the file never grew while it was being read");
        QVERIFY(got.isEmpty());
    }

    void readFile_fifo_refusedInsteadOfBlocking() {
        // open(2) on a fifo parks until a writer shows up. readFile runs on
        // the GUI thread, so a fifo named project.json inside a configured
        // root would freeze plasmashell — the type check has to come before
        // the open.
        const QString fifo = m_tmp.filePath("blocking.fifo");
        if (::mkfifo(QFile::encodeName(fifo).constData(), 0600) != 0)
            QSKIP("cannot create a fifo in the test temp dir");

        FileHelper helper;
        helper.addReadRoot(m_tmp.path());

        std::atomic<bool> done { false };
        QByteArray        result;
        std::thread       reader([&] {
            result = helper.readFile(fifo);
            done.store(true);
        });

        QElapsedTimer t;
        t.start();
        while (! done.load() && t.elapsed() < 3000) QThread::msleep(5);
        const bool returned = done.load();

        // Hand a still-parked reader its writer so the thread can be joined:
        // the O_WRONLY open completes its open(2), and closing right away
        // gives it EOF. With no reader waiting this is ENXIO and a no-op.
        QElapsedTimer unwedge;
        unwedge.start();
        while (! done.load() && unwedge.elapsed() < 5000) {
            const int w = ::open(QFile::encodeName(fifo).constData(), O_WRONLY | O_NONBLOCK);
            if (w >= 0) ::close(w);
            QThread::msleep(5);
        }
        reader.join();

        QVERIFY2(returned, "readFile must refuse a fifo, not block in open(2)");
        QVERIFY(result.isEmpty());
    }

    void readFile_characterDevice_refused() {
        // With no roots seeded nothing canonicalises the path away, and the
        // size cap cannot help: st_size is 0 for a character device, so the
        // only thing between /dev/zero and an unbounded readAll() is the
        // type check.
        if (! QFileInfo::exists("/dev/null")) QSKIP("no /dev/null on this system");
        FileHelper helper;
        QTest::ignoreMessage(QtWarningMsg, QRegularExpression("refused non-regular file"));
        QVERIFY(helper.readFile("/dev/null").isEmpty());
    }

    void readFile_fileUrlPrefix_readsTheSameBytes() {
        // requestReadFile strips file:// before opening; the sync path has to
        // agree or a QML caller passing a raw QUrl gets an empty result.
        const QString p = m_tmp.filePath("urlform.txt");
        QVERIFY(writeBytes(p, 5, 'u'));
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QCOMPARE(helper.readFile("file://" + p), QByteArray(5, 'u'));
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
        if (QFileInfo::exists("/etc/hostname")) QVERIFY(helper.readFile("/etc/hostname").isEmpty());
    }

    void clearReadRoots_resetsToPermissive() {
        if (! QFileInfo::exists("/etc/hostname")) QSKIP("no /etc/hostname witness");
        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QVERIFY(helper.readFile("/etc/hostname").isEmpty()); // gated
        helper.clearReadRoots();
        QVERIFY(! helper.readFile("/etc/hostname").isEmpty()); // permissive again
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

    // ── requestReadFile (async readFile via QThreadPool) ─────────────────────
    // Mirrors requestDirSize: canonicalise + allowlist + size-cap run inside
    // the worker thread; fileReadReady(path, contents, ok) is emitted on the
    // GUI thread. The path delivered in the signal is the caller-supplied
    // path (NOT the canonical form) so QML waiter maps keyed by the original
    // path work without a round-trip.

    void requestReadFile_emitsSignalWithContents() {
        QTemporaryDir td;
        QVERIFY(td.isValid());
        const QString path = td.filePath("hello.txt");
        QFile         f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("hello world");
        f.close();
        FileHelper helper;
        helper.addReadRoot(td.path());
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);
        helper.requestReadFile(path);
        QCOMPARE(spy.count(), 0); // async — nothing emitted synchronously
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 5000);
        const auto args = spy.takeFirst();
        QCOMPARE(args.at(0).toString(), path);
        QCOMPARE(args.at(1).toByteArray(), QByteArray("hello world"));
        QCOMPARE(args.at(2).toBool(), true);
    }

    void requestReadFile_rejectsOutsideAllowlist() {
        // /etc/hostname is universally readable on Linux — a clean witness
        // for "would have succeeded permissive; must be ok=false with an
        // allowlist seeded that does NOT include /etc".
        if (! QFileInfo::exists("/etc/hostname")) QSKIP("no /etc/hostname witness on this system");
        QTemporaryDir td;
        FileHelper    helper;
        helper.addReadRoot(td.path());
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);
        helper.requestReadFile("/etc/hostname");
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 5000);
        const auto args = spy.takeFirst();
        QCOMPARE(args.at(0).toString(), QStringLiteral("/etc/hostname"));
        QCOMPARE(args.at(2).toBool(), false);
        QVERIFY(args.at(1).toByteArray().isEmpty());
    }

    void requestReadFile_rejectsOverSizeLimit() {
        QTemporaryDir td;
        QVERIFY(td.isValid());
        const QString path = td.filePath("big.bin");
        QFile         f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        // 65 MiB > 64 MiB cap — use resize() for a sparse file to avoid
        // allocating 65 MiB of test heap.
        QVERIFY(f.resize(FileHelper::kMaxReadSize + 1));
        f.close();
        FileHelper helper;
        helper.addReadRoot(td.path());
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);
        helper.requestReadFile(path);
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 5000);
        const auto args = spy.takeFirst();
        QCOMPARE(args.at(2).toBool(), false);
        QVERIFY(args.at(1).toByteArray().isEmpty());
    }

    void requestReadFile_fifo_refusedInsteadOfParkingAWorker() {
        // A worker blocked in open(2) never returns, and ~FileHelper joins the
        // pool with no timeout — one fifo would deadlock plasmashell teardown.
        const QString fifo = m_tmp.filePath("async.fifo");
        if (::mkfifo(QFile::encodeName(fifo).constData(), 0600) != 0)
            QSKIP("cannot create a fifo in the test temp dir");

        FileHelper helper;
        helper.addReadRoot(m_tmp.path());
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);
        helper.requestReadFile(fifo);

        QElapsedTimer t;
        t.start();
        while (spy.count() == 0 && t.elapsed() < 3000) {
            QCoreApplication::processEvents();
            QThread::msleep(5);
        }
        const bool answered = spy.count() == 1;

        // Same unwedge as the sync case, and mandatory here: leaving the
        // worker parked would hang the destructor at the end of this function.
        QElapsedTimer unwedge;
        unwedge.start();
        while (spy.count() == 0 && unwedge.elapsed() < 5000) {
            const int w = ::open(QFile::encodeName(fifo).constData(), O_WRONLY | O_NONBLOCK);
            if (w >= 0) ::close(w);
            QCoreApplication::processEvents();
            QThread::msleep(5);
        }

        QVERIFY2(answered, "requestReadFile must refuse a fifo, not park a pool thread");
        const auto fifoArgs = spy.takeFirst();
        QCOMPARE(fifoArgs.at(2).toBool(), false);
        QVERIFY(fifoArgs.at(1).toByteArray().isEmpty());
    }

    void requestReadFile_characterDevice_refused() {
        // Permissive mode (no roots): st_size is 0 for a char device, so the
        // size cap is a no-op and only the type check refuses it.
        if (! QFileInfo::exists("/dev/null")) QSKIP("no /dev/null on this system");
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);
        helper.requestReadFile("/dev/null");
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 5000);
        const auto devArgs = spy.takeFirst();
        QCOMPARE(devArgs.at(2).toBool(), false);
        QVERIFY(devArgs.at(1).toByteArray().isEmpty());
    }

    void requestReadFile_concurrentBatch() {
        // 100 paths read in parallel must each emit a signal with ok=true.
        // Don't gate on wall time (CI may be slow); the guard is "every
        // request emitted exactly once, ok=true, contents match".
        QTemporaryDir td;
        QVERIFY(td.isValid());
        const int      N = 100;
        QList<QString> paths;
        for (int i = 0; i < N; ++i) {
            const QString p = td.filePath(QStringLiteral("f%1.txt").arg(i));
            QFile         f(p);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(QByteArray(1024, 'x'));
            f.close();
            paths.append(p);
        }
        FileHelper helper;
        helper.addReadRoot(td.path());
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);
        for (const auto& p : paths) helper.requestReadFile(p);
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), N, 10000);
        for (int i = 0; i < N; ++i) {
            QCOMPARE(spy.at(i).at(2).toBool(), true);
            QCOMPARE(spy.at(i).at(1).toByteArray().size(), qint64(1024));
        }
    }

    void requestReadFile_usesAllowlistSnapshotTakenAtDispatch() {
        // A settings change rewrites the allowlist (clearReadRoots() then a
        // fresh addReadRoot() per entry) while a library scan's worth of read
        // jobs is still queued. Each queued job must be judged by the allowlist
        // that was in force when it was dispatched, not by whatever the set
        // happens to hold when a pool thread finally picks the job up.
        //
        // Determinism comes from parking every pool thread in a long dirSize
        // walk first: the probes below cannot start until those drain, which
        // takes milliseconds, while the allowlist rewrite on this thread is two
        // calls and one realpath(). So the probes are guaranteed to still be
        // queued when the set changes underneath them.
        QTemporaryDir tdFiles, tdOther, tdBusy;
        QVERIFY(tdFiles.isValid());
        QVERIFY(tdOther.isValid());
        QVERIFY(tdBusy.isValid());

        FileHelper helper;
        if (! makeSlowWalkDir(helper, tdBusy.path(), 5))
            QSKIP("cannot make a slow enough walk dir on this filesystem");

        const int      kProbes = 16;
        QList<QString> probes;
        for (int i = 0; i < kProbes; ++i) {
            const QString p = tdFiles.filePath(QStringLiteral("p%1.json").arg(i));
            QVERIFY(writeBytes(p, 64));
            probes.append(p);
        }

        helper.addReadRoot(tdFiles.path());
        QSignalSpy spy(&helper, &FileHelper::fileReadReady);

        // Occupy every pool thread. requestDirSize shares m_pool but emits
        // dirSizeReady, so these never land in the fileReadReady spy.
        const int blockers = qMax(QThread::idealThreadCount(), 4) * 2;
        for (int i = 0; i < blockers; ++i) helper.requestDirSize(tdBusy.path(), 0);

        // Queued behind the blockers — none of these can have started yet.
        for (const QString& p : probes) helper.requestReadFile(p);

        // The settings change, exactly as QML performs it.
        helper.clearReadRoots();
        helper.addReadRoot(tdOther.path());

        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), kProbes, 60000);
        for (int i = 0; i < spy.count(); ++i) {
            QVERIFY2(spy.at(i).at(2).toBool(),
                     "a queued read was judged against the post-dispatch allowlist");
            // Contents too, so ok==true can't be satisfied by an empty read.
            QCOMPARE(spy.at(i).at(1).toByteArray().size(), qint64(64));
        }
    }

    void requestReadFile_allowlistChurnDuringDrainIsRaceFree() {
        // Memory-safety pin, not a behaviour test. Here the GUI thread and the
        // pool workers are genuinely inside the QSet at the same time: unfixed,
        // clearReadRoots() drops the last reference and frees the hash's span
        // array while a worker is walking it, so ASAN reports a
        // heap-use-after-free under isUnderAnyRoot — on the span itself or on a
        // QString element copied out of it, depending on where the worker got
        // caught. Functionally it can pass even unfixed — a
        // worker that happens to observe the transient empty set takes the
        // permissive branch and still returns the bytes — so its value is that
        // it drives the freed-node walk, not that it asserts. Don't
        // "simplify" it into the batch test.
        //
        // The churn is interleaved with the dispatch, not run after it: 400
        // jobs dispatch in a couple of milliseconds and a wide pool drains
        // them inside that window, so a trailing-only churn loop overlaps
        // nothing but the tail. Repeated rounds because thread scheduling is
        // not reproducible.
        QTemporaryDir td;
        QVERIFY(td.isValid());
        const int      N = 400;
        QList<QString> paths;
        for (int i = 0; i < N; ++i) {
            const QString p = td.filePath(QStringLiteral("c%1.json").arg(i));
            QVERIFY(writeBytes(p, 1024));
            paths.append(p);
        }

        for (int round = 0; round < 5; ++round) {
            FileHelper helper;
            helper.addReadRoot(td.path());
            QSignalSpy spy(&helper, &FileHelper::fileReadReady);

            for (int i = 0; i < N; ++i) {
                helper.requestReadFile(paths.at(i));
                if (i % 8 == 7) {
                    helper.clearReadRoots();
                    helper.addReadRoot(td.path());
                }
            }
            for (int i = 0; i < 200; ++i) {
                helper.clearReadRoots();
                helper.addReadRoot(td.path());
            }

            QTRY_COMPARE_WITH_TIMEOUT(spy.count(), N, 30000);
            // A dispatch never lands between a clear() and its paired
            // addReadRoot() — both run on this thread — so every snapshot is
            // the seeded root and every read must succeed.
            for (int i = 0; i < N; ++i) {
                QCOMPARE(spy.at(i).at(2).toBool(), true);
                QCOMPARE(spy.at(i).at(1).toByteArray().size(), qint64(1024));
            }
        }
    }

    void requestReadFile_dtorWaitsForInflight() {
        // Destroying the helper while a request is in flight must not crash;
        // ~FileHelper drains m_pool via waitForDone(). Silent on glibc without
        // ASAN/TSan; pins the contract.
        QTemporaryDir td;
        QVERIFY(td.isValid());
        const QString p = td.filePath("x.txt");
        QFile         f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("x");
        f.close();
        {
            FileHelper helper;
            helper.addReadRoot(td.path());
            helper.requestReadFile(p);
            // Immediate dtor — m_pool::waitForDone() must drain.
        }
        QCoreApplication::processEvents(); // drain queued events
        QVERIFY(true);                     // no sanitizer trip, no hang
    }

    // ── watchWallpaperDir (QFileSystemWatcher on workshop dirs) ─────────────
    // Inotify-backed watcher attached to the top-level workshop directory.
    // Subdir add / remove fires directoryChanged → wallpaperDirChanged on the
    // GUI thread. Tests use mkdir / rm to drive the underlying inotify event.

    void watchWallpaperDir_emitsSignalOnSubdirAdd() {
        QTemporaryDir td;
        QVERIFY(td.isValid());
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::wallpaperDirChanged);
        helper.watchWallpaperDir(td.path());
        // Inotify is async; wait for the kernel to attach the watch then
        // create a subdir to trigger directoryChanged.
        QVERIFY(QDir(td.path()).mkdir("newwp"));
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
        QCOMPARE(spy.first().at(0).toString(), td.path());
    }

    void watchWallpaperDir_emitsSignalOnSubdirRemove() {
        QTemporaryDir td;
        QVERIFY(td.isValid());
        QVERIFY(QDir(td.path()).mkdir("tobedeleted"));
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::wallpaperDirChanged);
        helper.watchWallpaperDir(td.path());
        QVERIFY(QDir(td.path() + "/tobedeleted").removeRecursively());
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
    }

    void watchWallpaperDir_dedupAddSamePath() {
        // QFileSystemWatcher's addPath is idempotent — re-adding a watched
        // path is a no-op. We can't directly observe the dedup (Qt exposes
        // no per-path watch count), but we CAN observe that a single mkdir
        // still produces a sane number of emissions (≥ 1, not double).
        QTemporaryDir td;
        QVERIFY(td.isValid());
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::wallpaperDirChanged);
        helper.watchWallpaperDir(td.path());
        helper.watchWallpaperDir(td.path()); // dedup
        QVERIFY(QDir(td.path()).mkdir("once"));
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
        // The watch is single, not double, so we don't see 2x emissions.
        // (A single mkdir can produce 1-3 raw inotify events depending on
        // FS — but no MORE than that.)
        QVERIFY2(spy.count() <= 4, "duplicate addPath produced extra emissions");
    }

    void unwatchAllWallpaperDirs_stopsSignals() {
        QTemporaryDir td;
        QVERIFY(td.isValid());
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::wallpaperDirChanged);
        helper.watchWallpaperDir(td.path());
        helper.unwatchAllWallpaperDirs();
        QVERIFY(QDir(td.path()).mkdir("after_unwatch"));
        QTest::qWait(500); // give the watcher time to (NOT) fire
        QCOMPARE(spy.count(), 0);
    }

    void watchWallpaperDir_emptyPath_isNoOp() {
        // Empty path early-returns; no watcher constructed, no emission.
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::wallpaperDirChanged);
        helper.watchWallpaperDir(QString());
        // Subsequent unwatch on a never-constructed watcher must not crash.
        helper.unwatchAllWallpaperDirs();
        QCOMPARE(spy.count(), 0);
    }

    void watchWallpaperDir_nonexistentPath_warnsAndNoOps() {
        // Non-existent paths log a warning + early-return.
        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::wallpaperDirChanged);
        helper.watchWallpaperDir("/tmp/wekde_test_never_existed_zzz");
        QTest::qWait(200);
        QCOMPARE(spy.count(), 0);
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

    void permissionsNamespace_roundTripsThroughWallpaperConfig() {
        // The consent layer persists per-(workshop-id, feature) decisions as
        //   cfg.permissions = { "1": "allow", "2": "deny", ... }
        // Lock the nested map round-trip in so a future serialisation refactor
        // can't silently flatten and break consent.
        FileHelper    helper;
        const QString id = "424242";
        QVariantMap   cfg;
        QVariantMap   perms;
        perms["1"]         = "allow";
        perms["2"]         = "deny";
        cfg["permissions"] = perms;
        helper.writeWallpaperConfig(id, cfg);

        const QVariantMap got = helper.readWallpaperConfig(id);
        QVERIFY(got.contains("permissions"));
        const QVariantMap roundtrip = got["permissions"].toMap();
        QCOMPARE(roundtrip.value("1").toString(), QStringLiteral("allow"));
        QCOMPARE(roundtrip.value("2").toString(), QStringLiteral("deny"));

        helper.resetWallpaperConfig(id);
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

    void patchedHtml_fifo_refusedInsteadOfBlocking() {
        // A web wallpaper's index.html is whatever the wallpaper directory
        // holds; patchedHtml runs on the GUI thread, so a fifo there would
        // hang the compositor in open(2).
        const QString fifo = m_tmp.filePath("page.fifo");
        if (::mkfifo(QFile::encodeName(fifo).constData(), 0600) != 0)
            QSKIP("cannot create a fifo in the test temp dir");

        FileHelper        helper;
        std::atomic<bool> done { false };
        QString           result;
        std::thread       reader([&] {
            result = helper.patchedHtml(fifo);
            done.store(true);
        });

        QElapsedTimer t;
        t.start();
        while (! done.load() && t.elapsed() < 3000) QThread::msleep(5);
        const bool returned = done.load();

        QElapsedTimer unwedge;
        unwedge.start();
        while (! done.load() && unwedge.elapsed() < 5000) {
            const int w = ::open(QFile::encodeName(fifo).constData(), O_WRONLY | O_NONBLOCK);
            if (w >= 0) ::close(w);
            QThread::msleep(5);
        }
        reader.join();

        QVERIFY2(returned, "patchedHtml must refuse a fifo, not block in open(2)");
        QVERIFY(result.isEmpty());
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

    void patchedHtml_uncaughtErrorPrefixUsesPagePrefix() {
        // The page-side error / unhandledrejection shim must route through
        // console.error (level 2) with the [WEK-page UNCAUGHT] / [WEK-page
        // UNHANDLED-PROMISE] prefixes so the journal `grep WEK-page` flow
        // works and the QML onJavaScriptConsoleMessage handler fires at
        // level 2.  Locks the contract against a silent revert of the
        // narrowing pass.
        QString path = m_tmp.filePath("uncaught.html");
        QFile   f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<html><head></head><body></body></html>");
        f.close();

        FileHelper helper;
        QString    result = helper.patchedHtml(path);

        QVERIFY(result.contains("[WEK-page UNCAUGHT]"));
        QVERIFY(result.contains("[WEK-page UNHANDLED-PROMISE]"));
        QVERIFY(result.contains("[WEK-page STACK]"));
        QVERIFY(result.contains("console.error"));
        // Legacy '[WEK] ERROR:' / '[WEK] REJECTION:' tags are gone.
        QVERIFY(! result.contains("'[WEK] ERROR:'"));
        QVERIFY(! result.contains("'[WEK] REJECTION:'"));
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

    void atomicWriteJson_targetIsNeverAbsentWhileBeingReplaced() {
        // The point of the temp-file dance is that a concurrent reader always
        // sees either the old file or the new one. Unlinking the target before
        // the rename opens a window where it sees neither.
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = d.path() + "/data.json";
        QJsonObject   seed;
        seed["v"] = 0;
        QVERIFY(FileHelper::atomicWriteJson(path, QJsonDocument(seed)));

        const QByteArray  native = QFile::encodeName(path);
        std::atomic<bool> stop { false };
        std::atomic<int>  misses { 0 };
        std::atomic<int>  polls { 0 };
        std::thread       watcher([&] {
            while (! stop.load(std::memory_order_relaxed)) {
                if (::access(native.constData(), F_OK) != 0)
                    misses.fetch_add(1, std::memory_order_relaxed);
                polls.fetch_add(1, std::memory_order_relaxed);
            }
        });

        bool allWrote = true;
        for (int i = 1; i <= 400 && allWrote; ++i) {
            QJsonObject o;
            o["v"]   = i;
            allWrote = FileHelper::atomicWriteJson(path, QJsonDocument(o));
        }
        stop.store(true);
        watcher.join();

        QVERIFY(allWrote);
        QVERIFY2(polls.load() > 0, "watcher thread never polled");
        QCOMPARE(misses.load(), 0);
    }

    void atomicWriteJson_fsyncThatCannotSync_stillCountsAsWritten() {
        // Some mounts (FUSE ones especially) answer fsync(2) with EINVAL
        // because there is nothing for them to push. Nothing was lost, so the
        // write has to stand. A fifo is the cheapest local stand-in — the
        // kernel hands back the same EINVAL for a pipe fd.
        int probe[2];
        QVERIFY(::pipe(probe) == 0);
        errno                      = 0;
        const bool pipeGivesEinval = ::fsync(probe[1]) != 0 && errno == EINVAL;
        ::close(probe[0]);
        ::close(probe[1]);
        if (! pipeGivesEinval) QSKIP("fsync on a pipe does not fail with EINVAL here");

        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString path = d.path() + "/fifo-target.json";
        const QString tmp  = path + ".tmp";
        if (::mkfifo(QFile::encodeName(tmp).constData(), 0600) != 0)
            QSKIP("cannot create a fifo in the test temp dir");
        // Something has to hold the read end open or the writer's open(2)
        // parks; the pipe buffer swallows a document this small on its own, so
        // the reader never has to drain it.
        const int rd = ::open(QFile::encodeName(tmp).constData(), O_RDONLY | O_NONBLOCK);
        QVERIFY(rd >= 0);

        QJsonObject obj;
        obj["k"]      = "v";
        const bool ok = FileHelper::atomicWriteJson(path, QJsonDocument(obj));
        ::close(rd);
        QVERIFY2(ok, "an fsync answering EINVAL must not be reported as a failed write");
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

    // The shape production actually passes. The renderer builds its cache dir
    // straight from $XDG_CACHE_HOME with no application-name segment, so
    // plugin_info.cache_path is a SIBLING of the host application's
    // QStandardPaths::CacheLocation, never a child of it. Every pre-existing
    // cache case below builds its fixture from CacheLocation — the same
    // expression the guard used — so none of them ever saw this geometry.
    // mkpath the generic root first: canonicalFilePath() on a directory that
    // doesn't exist yet returns an empty string.
    static QString rendererCacheFixture() {
        const QString generic =
            QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
        if (generic.isEmpty()) return QString();
        QDir().mkpath(generic);
        return wekde::cache_paths::rendererCacheDir();
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
        // Rooted at the guard's own root, not CacheLocation: CacheLocation is
        // now a child of it, so "<CacheLocation>-sibling" would be *inside* the
        // guard root and this case would assert the opposite of its name.
        const QString generic =
            QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
        QVERIFY(! generic.isEmpty());
        QDir().mkpath(generic);
        const QString root = QFileInfo(generic).canonicalFilePath();
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

    // A strict child of the guard root is accepted. This used to double as the
    // "clear the live binding target" case, but plugin_info.cache_path is
    // <user cache>/wescene-renderer now — see
    // clearCacheDir_acceptsRendererCacheDirBesideHostAppCache for that.
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

    // ── pruneOrphanThumbnails (orphan-GC) ────────────────────────────────────
    //
    // Orphan-GC is conservative: only sidecar-anchored thumbnails are
    // candidates. Entries without a sidecar are kept (backwards-safe for
    // pre-feature caches).
    void pruneOrphanThumbnails_removesOrphansKeepsLive() {
        // Callers hand over the cache ROOT; the thumbnails live one level down
        // in video-thumbs/, which is where the walk has to look.
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-prune-A";
        const QString thumbDir = cacheRoot + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString path;
            ~Cleanup() { QDir(path).removeRecursively(); }
        } cu { cacheRoot };

        QTemporaryDir realDir;
        QVERIFY(realDir.isValid());
        // live source — touched real file
        const QString liveSrc = realDir.path() + "/clip.mp4";
        QFile         lf(liveSrc);
        QVERIFY(lf.open(QIODevice::WriteOnly));
        lf.write("x");
        lf.close();

        // Orphan entry: abc.jpg + abc.meta pointing at a deleted file.
        QVERIFY(writeBytes(thumbDir + "/abc.jpg", 1024));
        QFile am(thumbDir + "/abc.meta");
        QVERIFY(am.open(QIODevice::WriteOnly));
        am.write(QJsonDocument(QJsonObject { { "src", "/nonexistent.mp4" } })
                     .toJson(QJsonDocument::Compact));
        am.close();

        // Live entry: def.jpg + def.meta pointing at the touched real file.
        QVERIFY(writeBytes(thumbDir + "/def.jpg", 2048));
        QFile dm(thumbDir + "/def.meta");
        QVERIFY(dm.open(QIODevice::WriteOnly));
        dm.write(QJsonDocument(QJsonObject { { "src", liveSrc } }).toJson(QJsonDocument::Compact));
        dm.close();

        // No-sidecar entry: kept (backwards-safe).
        QVERIFY(writeBytes(thumbDir + "/nosc.jpg", 512));

        FileHelper fh;
        const auto freed = fh.pruneOrphanThumbnails(cacheRoot, {}, { realDir.path() });
        QVERIFY(freed > 0);
        QVERIFY(! QFile::exists(thumbDir + "/abc.jpg"));
        QVERIFY(! QFile::exists(thumbDir + "/abc.meta"));
        QVERIFY(QFile::exists(thumbDir + "/def.jpg"));
        QVERIFY(QFile::exists(thumbDir + "/def.meta"));
        QVERIFY(QFile::exists(thumbDir + "/nosc.jpg")); // backwards-safe
    }

    void pruneOrphanThumbnails_skipsEntriesWithoutSidecar() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-prune-B";
        const QString thumbDir = cacheRoot + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };

        QVERIFY(writeBytes(thumbDir + "/legacy.jpg", 256));
        FileHelper fh;
        QCOMPARE(fh.pruneOrphanThumbnails(cacheRoot, {}, {}), qint64 { 0 });
        QVERIFY(QFile::exists(thumbDir + "/legacy.jpg"));
    }

    void pruneOrphanThumbnails_refusesPathOutsideCacheRoot() {
        // /tmp is NOT under QStandardPaths::CacheLocation (in test mode the
        // location lives under m_tmp); pass /tmp as the cache root and
        // expect the belt to refuse.
        FileHelper fh;
        QCOMPARE(fh.pruneOrphanThumbnails("/tmp", {}, {}), qint64 { 0 });
    }

    // The seeded root IS mounted and the source under it is gone: that source
    // is not coming back, so the thumbnail is an orphan. (The old version of
    // this case created the file it claimed was missing, so it only ever
    // exercised the exists() short-circuit and proved nothing about roots.)
    void pruneOrphanThumbnails_reapsWhenRootPresentButSrcDeleted() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-prune-C";
        const QString thumbDir = cacheRoot + "/video-thumbs";
        QDir().mkpath(thumbDir);
        QTemporaryDir wsRoot;
        QVERIFY(wsRoot.isValid());
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };

        const QString src = wsRoot.path() + "/sub/preview.mp4";
        QVERIFY(! QFileInfo::exists(src));

        QVERIFY(writeBytes(thumbDir + "/keep.jpg", 100));
        QFile m(thumbDir + "/keep.meta");
        QVERIFY(m.open(QIODevice::WriteOnly));
        m.write(QJsonDocument(QJsonObject { { "src", src } }).toJson(QJsonDocument::Compact));
        m.close();

        FileHelper fh;
        QVERIFY(fh.pruneOrphanThumbnails(cacheRoot, { wsRoot.path() }, {}) > 0);
        QVERIFY(! QFile::exists(thumbDir + "/keep.jpg"));
        QVERIFY(! QFile::exists(thumbDir + "/keep.meta"));
    }

    // Same shape, but the seeded root itself is gone (Steam library on an
    // unplugged drive / unmounted share). Nothing can be judged an orphan
    // while the root it lived under is invisible — keep the thumbnail.
    void pruneOrphanThumbnails_keepsThumbWhenSourceRootIsUnmounted() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-prune-D";
        const QString thumbDir = cacheRoot + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };

        QString wsRootPath;
        {
            QTemporaryDir wsRoot;
            QVERIFY(wsRoot.isValid());
            wsRootPath = wsRoot.path();
        }
        QVERIFY(! QFileInfo::exists(wsRootPath)); // "drive unplugged"
        const QString src = wsRootPath + "/431960/3662790108/clip.mp4";

        QVERIFY(writeBytes(thumbDir + "/keep.jpg", 100));
        QFile m(thumbDir + "/keep.meta");
        QVERIFY(m.open(QIODevice::WriteOnly));
        m.write(QJsonDocument(QJsonObject { { "src", src } }).toJson(QJsonDocument::Compact));
        m.close();

        FileHelper fh;
        QCOMPARE(fh.pruneOrphanThumbnails(cacheRoot, { wsRootPath }, {}), qint64 { 0 });
        QVERIFY(QFile::exists(thumbDir + "/keep.jpg"));
    }

    // ── enforceCacheQuota (LRU eviction) ─────────────────────────────────────
    void enforceCacheQuota_zeroIsUnlimited() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-quota-Z";
        QDir().mkpath(cacheRoot);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };
        QVERIFY(writeBytes(cacheRoot + "/big.jpg", 5 * 1024 * 1024));
        FileHelper fh;
        QCOMPARE(fh.enforceCacheQuotaForce({ cacheRoot }, 0), qint64 { 0 });
        QVERIFY(QFile::exists(cacheRoot + "/big.jpg"));
    }

    void enforceCacheQuota_underQuotaIsNoOp() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-quota-U";
        QDir().mkpath(cacheRoot);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };
        QVERIFY(writeBytes(cacheRoot + "/small.jpg", 1024));
        FileHelper fh;
        QCOMPARE(fh.enforceCacheQuotaForce({ cacheRoot }, 10 * 1024 * 1024), qint64 { 0 });
        QVERIFY(QFile::exists(cacheRoot + "/small.jpg"));
    }

    void enforceCacheQuota_keepsRecentEvictsOld() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-quota-E";
        QDir().mkpath(cacheRoot);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };

        // Two 1MB files. Make oldF mtime older so the heuristic picks it.
        QVERIFY(writeBytes(cacheRoot + "/oldF.jpg", 1024 * 1024));
        QVERIFY(writeBytes(cacheRoot + "/newF.jpg", 1024 * 1024));
        // Bump the oldF file's mtime backwards by 7 days so atime-fallback
        // picks it for eviction first (utimensat would be cleanest but
        // QFile lacks a direct helper; setFileTime covers atime+mtime).
        QFile of(cacheRoot + "/oldF.jpg");
        QVERIFY(of.open(QIODevice::ReadWrite));
        QVERIFY(
            of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileModificationTime));
        QVERIFY(of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime));
        of.close();
        QFile nf(cacheRoot + "/newF.jpg");
        QVERIFY(nf.open(QIODevice::ReadWrite));
        QVERIFY(nf.setFileTime(QDateTime::currentDateTime(), QFile::FileAccessTime));
        nf.close();

        FileHelper   fh;
        const qint64 quota = static_cast<qint64>(1.5 * 1024 * 1024); // fits one, not two
        const qint64 freed = fh.enforceCacheQuotaForce({ cacheRoot }, quota);
        QVERIFY(freed >= 1024 * 1024); // oldF gone
        QVERIFY(! QFile::exists(cacheRoot + "/oldF.jpg"));
        QVERIFY(QFile::exists(cacheRoot + "/newF.jpg"));
        QCOMPARE(fh.lastGcBytesFreed(), freed);
    }

    void enforceCacheQuota_evictsSidecarWithJpg() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-quota-S";
        QDir().mkpath(cacheRoot);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };

        QVERIFY(writeBytes(cacheRoot + "/oldF.jpg", 1024 * 1024));
        QFile mm(cacheRoot + "/oldF.meta");
        QVERIFY(mm.open(QIODevice::WriteOnly));
        mm.write(QJsonDocument(QJsonObject { { "src", "/nonexistent" } })
                     .toJson(QJsonDocument::Compact));
        mm.close();
        QVERIFY(writeBytes(cacheRoot + "/newF.jpg", 1024 * 1024));

        // Age the oldF pair so it's the eviction target. Eviction keys on
        // max(atime, mtime), so the mtime must be aged too — an atime-only bump
        // is masked by the just-written mtime and leaves oldF.jpg, oldF.meta and
        // newF.jpg all tied at "now", making which one gets evicted depend on
        // std::sort's tie-handling and the filesystem's mtime resolution.
        QFile of(cacheRoot + "/oldF.jpg");
        QVERIFY(of.open(QIODevice::ReadWrite));
        QVERIFY(
            of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileModificationTime));
        QVERIFY(of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime));
        of.close();

        FileHelper fh;
        fh.enforceCacheQuotaForce({ cacheRoot }, 1500 * 1024);
        QVERIFY(! QFile::exists(cacheRoot + "/oldF.jpg"));
        QVERIFY(! QFile::exists(cacheRoot + "/oldF.meta")); // sidecar gone too
    }

    void enforceCacheQuota_throttledByDefault() {
        const QString cacheRoot =
            QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/wekde-test-quota-T";
        QDir().mkpath(cacheRoot);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { cacheRoot };

        QVERIFY(writeBytes(cacheRoot + "/a.jpg", 1024 * 1024));
        QVERIFY(writeBytes(cacheRoot + "/b.jpg", 1024 * 1024));
        QFile a(cacheRoot + "/a.jpg");
        QVERIFY(a.open(QIODevice::ReadWrite));
        a.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime);
        a.close();

        FileHelper   fh;
        const qint64 first = fh.enforceCacheQuota({ cacheRoot }, 1500 * 1024);
        QVERIFY(first >= 1024 * 1024);

        // Add a new file then call again — throttle should keep it (returns
        // the previous freed total, no work).
        QVERIFY(writeBytes(cacheRoot + "/c.jpg", 1024 * 1024));
        QFile cc(cacheRoot + "/c.jpg");
        QVERIFY(cc.open(QIODevice::ReadWrite));
        cc.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime);
        cc.close();
        const qint64 second = fh.enforceCacheQuota({ cacheRoot }, 1500 * 1024);
        QCOMPARE(second, first);
        QVERIFY(QFile::exists(cacheRoot + "/c.jpg")); // not evicted by throttled call
    }

    void enforceCacheQuota_refusesRootsOutsideCacheLocation() {
        FileHelper    fh;
        QTemporaryDir outside;
        QVERIFY(outside.isValid());
        QVERIFY(writeBytes(outside.path() + "/x.jpg", 100));
        // /tmp is outside QStandardPaths::CacheLocation; nothing freed.
        QCOMPARE(fh.enforceCacheQuotaForce({ outside.path() }, 1), qint64 { 0 });
        QVERIFY(QFile::exists(outside.path() + "/x.jpg"));
    }

    // ── cache guards against the geometry production actually passes ─────────
    //
    // plugin_info.cache_path is <user cache>/wescene-renderer. Everything
    // below builds its fixture there instead of under CacheLocation, so a
    // guard that only ever accepted its own root formula fails these.

    // Tripwire. If this ever goes green-by-accident because the fixture moved
    // inside CacheLocation, every case in this block becomes tautological
    // again — exactly the state this suite was in before.
    void cacheGuard_rendererCacheIsSiblingNotChildOfAppCache() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        const QString appCache = cacheRootCanonical();
        QVERIFY(! appCache.isEmpty());
        QVERIFY2(! fixture.startsWith(appCache + "/"),
                 "fixture is inside CacheLocation — the guard cases below prove nothing");
        QVERIFY2(fixture != appCache, "fixture IS CacheLocation");
    }

    // Pin the plugin's path formula against the renderer's own. These are the
    // two expressions that drifted apart: Qt's GenericCacheLocation and
    // platform::GetCachePath's raw $XDG_CACHE_HOME rule must land on the same
    // directory. Nothing here deletes anything — the env swap exists only so
    // the comparison runs against a directory we own.
    void cacheGuard_matchesTheRendererOwnCachePathFormula() {
        struct ModeGuard {
            QByteArray prevXdg;
            bool       hadXdg;
            ~ModeGuard() {
                if (hadXdg)
                    qputenv("XDG_CACHE_HOME", prevXdg);
                else
                    qunsetenv("XDG_CACHE_HOME");
                QStandardPaths::setTestModeEnabled(true);
            }
        } guard { qgetenv("XDG_CACHE_HOME"), qEnvironmentVariableIsSet("XDG_CACHE_HOME") };

        QTemporaryDir xdg;
        QVERIFY(xdg.isValid());
        const QString xdgCanon = QFileInfo(xdg.path()).canonicalFilePath();
        QVERIFY(! xdgCanon.isEmpty());
        // Point the environment at our own dir BEFORE leaving test mode, so
        // neither formula can ever resolve to the developer's real cache.
        qputenv("XDG_CACHE_HOME", xdgCanon.toLocal8Bit());
        QStandardPaths::setTestModeEnabled(false);

        const QString fromRenderer = QString::fromStdString(
            wallpaper::platform::GetCachePath(wallpaper::platform::kRendererCacheDir).string());
        const QString fromPlugin = wekde::cache_paths::rendererCacheDir();
        QCOMPARE(fromPlugin, fromRenderer);
    }

    void clearCacheDir_acceptsRendererCacheDirBesideHostAppCache() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        QDir().mkpath(fixture + "/3662790108/spvs01");
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };
        const QString spv = fixture + "/3662790108/spvs01/abc.spvs";
        QVERIFY(writeBytes(spv, 4096));

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(fixture), true);
        QVERIFY(! QFile::exists(spv));
        // The dir itself survives so plugin_info.cache_path stays valid.
        QVERIFY(QFileInfo(fixture).exists());
    }

    // The guard root widened to the whole user cache, and isUnderRoot accepts
    // an exact match — so without a strict-descendant clause a stray
    // cache_path of "~/.cache" would wipe every application's cache.
    void clearCacheDir_refusesUserCacheRootItself() {
        const QString generic =
            QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
        QVERIFY(! generic.isEmpty());
        QDir().mkpath(generic);
        const QString root = QFileInfo(generic).canonicalFilePath();
        QVERIFY(! root.isEmpty());
        const QString victim = root + "/wek-guard-victim.txt";
        QVERIFY(writeBytes(victim, 32));

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(root), false);
        QVERIFY(QFile::exists(victim));
        QFile::remove(victim);
    }

    // "Clear shader cache" must not take the user's save data with it.
    // SceneScript localStorage lives under the same root and is never
    // regenerated.
    void clearCacheDir_keepsLocalStorageJson() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        QDir().mkpath(fixture + "/3662790108/spvs01");
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };
        const QString global   = fixture + "/localstorage_global.json";
        const QString perScene = fixture + "/3662790108/localstorage.json";
        const QString spv      = fixture + "/3662790108/spvs01/abc.spvs";
        QVERIFY(writeBytes(global, 128));
        QVERIFY(writeBytes(perScene, 128));
        QVERIFY(writeBytes(spv, 4096));

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(fixture), true);
        QVERIFY(! QFile::exists(spv));
        QVERIFY2(QFile::exists(global), "localstorage_global.json was deleted by clearCacheDir");
        QVERIFY2(QFile::exists(perScene),
                 "<sceneId>/localstorage.json was deleted by clearCacheDir");
    }

    // The plugin .so is dlopen'd into plasmashell; an unbounded recursion here
    // takes the whole desktop shell down with it.
    void clearCacheDir_refusesPathologicallyDeepTree() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };
        QString deep = fixture;
        for (int i = 0; i < 40; ++i) deep += QStringLiteral("/d");
        QVERIFY(QDir().mkpath(deep));

        FileHelper fh;
        QCOMPARE(fh.clearCacheDir(fixture), false);
    }

    // main.qml hands over the cache ROOT; the thumbnails are one level down.
    // Deriving the subdirectory in C++ is what keeps the writer
    // (VideoListModel) and the reaper on one definition.
    void videoThumbDir_derivesFromCacheRootAndStripsFileUri() {
        QCOMPARE(FileHelper::videoThumbDir("/home/u/.cache/wescene-renderer"),
                 QStringLiteral("/home/u/.cache/wescene-renderer/video-thumbs"));
        QCOMPARE(FileHelper::videoThumbDir("file:///home/u/.cache/wescene-renderer"),
                 QStringLiteral("/home/u/.cache/wescene-renderer/video-thumbs"));
        QCOMPARE(FileHelper::videoThumbDir("/home/u/.cache/wescene-renderer/"),
                 QStringLiteral("/home/u/.cache/wescene-renderer/video-thumbs"));
        QCOMPARE(FileHelper::videoThumbDir(""), QString());
    }

    void pruneOrphanThumbnails_derivesVideoThumbsFromCacheRoot() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        const QString thumbDir = fixture + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };

        QTemporaryDir realDir;
        QVERIFY(realDir.isValid());
        const QString liveSrc = realDir.path() + "/clip.mp4";
        QVERIFY(writeBytes(liveSrc, 8));

        QVERIFY(writeBytes(thumbDir + "/abc.jpg", 1024));
        QFile am(thumbDir + "/abc.meta");
        QVERIFY(am.open(QIODevice::WriteOnly));
        am.write(QJsonDocument(QJsonObject { { "src", "/nonexistent.mp4" } })
                     .toJson(QJsonDocument::Compact));
        am.close();

        QVERIFY(writeBytes(thumbDir + "/def.jpg", 2048));
        QFile dm(thumbDir + "/def.meta");
        QVERIFY(dm.open(QIODevice::WriteOnly));
        dm.write(QJsonDocument(QJsonObject { { "src", liveSrc } }).toJson(QJsonDocument::Compact));
        dm.close();

        FileHelper fh;
        // The CACHE ROOT, exactly as main.qml passes it.
        QVERIFY(fh.pruneOrphanThumbnails(fixture, {}, { realDir.path() }) > 0);
        QVERIFY(! QFile::exists(thumbDir + "/abc.jpg"));
        QVERIFY(! QFile::exists(thumbDir + "/abc.meta"));
        QVERIFY(QFile::exists(thumbDir + "/def.jpg"));
    }

    void enforceCacheQuota_evictsInsideRendererCacheDir() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        const QString thumbDir = fixture + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };

        QVERIFY(writeBytes(thumbDir + "/oldF.jpg", 1024 * 1024));
        QVERIFY(writeBytes(thumbDir + "/newF.jpg", 1024 * 1024));
        // Eviction keys on max(atime, mtime), so both have to move back.
        QFile of(thumbDir + "/oldF.jpg");
        QVERIFY(of.open(QIODevice::ReadWrite));
        QVERIFY(
            of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileModificationTime));
        QVERIFY(of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime));
        of.close();

        FileHelper   fh;
        const qint64 freed =
            fh.enforceCacheQuotaForce({ fixture }, static_cast<qint64>(1.5 * 1024 * 1024));
        QVERIFY(freed >= 1024 * 1024);
        QVERIFY(! QFile::exists(thumbDir + "/oldF.jpg"));
        QVERIFY(QFile::exists(thumbDir + "/newF.jpg"));
    }

    // The headline data-loss case. The LRU walk sees localstorage_global.json
    // as just another old file; once the guard lets the walk run at all, the
    // first time a user crosses the quota their SceneScript state goes.
    void enforceCacheQuota_keepsLocalStorageJson() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        QDir().mkpath(fixture + "/3662790108/spvs01");
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };

        const QString global   = fixture + "/localstorage_global.json";
        const QString perScene = fixture + "/3662790108/localstorage.json";
        const QString spv      = fixture + "/3662790108/spvs01/x.spvs";
        QVERIFY(writeBytes(global, 1024 * 1024));
        QVERIFY(writeBytes(perScene, 1024 * 1024));
        QVERIFY(writeBytes(spv, 1024 * 1024));
        // Make the two localstorage files the OLDEST entries, i.e. the ones a
        // plain LRU sweep reaches for first.
        for (const QString& p : { global, perScene }) {
            QFile f(p);
            QVERIFY(f.open(QIODevice::ReadWrite));
            QVERIFY(f.setFileTime(QDateTime::currentDateTime().addDays(-7),
                                  QFile::FileModificationTime));
            QVERIFY(f.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime));
            f.close();
        }

        FileHelper fh;
        fh.enforceCacheQuotaForce({ fixture }, static_cast<qint64>(1.5 * 1024 * 1024));
        QVERIFY2(QFile::exists(global), "LRU eviction deleted localstorage_global.json");
        QVERIFY2(QFile::exists(perScene), "LRU eviction deleted <sceneId>/localstorage.json");
        // And it still did its job on the regenerable entry.
        QVERIFY(! QFile::exists(spv));
    }

#ifndef Q_OS_WIN
    // clearCacheDir and pruneOrphanThumbnails both re-canonicalise every entry
    // before touching it; the quota walk did not. An entry whose real target is
    // outside the cache is not cache — don't count its bytes and don't delete
    // it.
    void enforceCacheQuota_skipsEntryEscapingCacheRoot() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        QDir().mkpath(fixture);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };

        QTemporaryDir outside;
        QVERIFY(outside.isValid());
        const QString target = outside.path() + "/precious.jpg";
        QVERIFY(writeBytes(target, 2 * 1024 * 1024));
        {
            QFile f(target);
            QVERIFY(f.open(QIODevice::ReadWrite));
            // Oldest thing in sight: a plain LRU sweep evicts it first.
            QVERIFY(f.setFileTime(QDateTime::currentDateTime().addDays(-30),
                                  QFile::FileModificationTime));
            QVERIFY(
                f.setFileTime(QDateTime::currentDateTime().addDays(-30), QFile::FileAccessTime));
            f.close();
        }
        const QString link = fixture + "/escape.jpg";
        QVERIFY(QFile::link(target, link));
        QVERIFY(writeBytes(fixture + "/local.jpg", 1024 * 1024));

        FileHelper fh;
        fh.enforceCacheQuotaForce({ fixture }, 1024);
        QVERIFY2(QFileInfo(link).isSymLink(), "the escaping entry was unlinked by the quota walk");
        QVERIFY(QFile::exists(target));
        // The genuine cache entry is still fair game.
        QVERIFY(! QFile::exists(fixture + "/local.jpg"));
    }
#endif

    // ── requestCacheGc — the startup pass must not run on the caller's thread ─
    //
    // main.qml fires this from Component.onCompleted, which is plasmashell's
    // GUI thread. A synchronous stat walk of a populated shader cache stalls
    // the whole shell at every login.
    void requestCacheGc_runsOnThePoolNotTheCallingThread() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        const QString thumbDir = fixture + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };

        QVERIFY(writeBytes(thumbDir + "/abc.jpg", 1024));
        QFile am(thumbDir + "/abc.meta");
        QVERIFY(am.open(QIODevice::WriteOnly));
        am.write(QJsonDocument(QJsonObject { { "src", "/nonexistent.mp4" } })
                     .toJson(QJsonDocument::Compact));
        am.close();

        FileHelper    fh;
        QTemporaryDir busy;
        QVERIFY(busy.isValid());
        if (! makeSlowWalkDir(fh, busy.path(), 5))
            QSKIP("cannot make a slow enough walk dir on this filesystem");

        QSignalSpy spy(&fh, &FileHelper::cacheGcFinished);
        // Park every pool thread in a long job, so a GC dispatched now
        // provably cannot have started yet.
        const int blockers = qMax(QThread::idealThreadCount(), 4) * 2;
        for (int i = 0; i < blockers; ++i) fh.requestDirSize(busy.path(), 0);

        fh.requestCacheGc(fixture, {}, {}, 0);
        QCOMPARE(spy.count(), 0);
        QVERIFY2(QFile::exists(thumbDir + "/abc.jpg"),
                 "requestCacheGc did the walk on the calling thread");

        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 60000);
        QVERIFY(! QFile::exists(thumbDir + "/abc.jpg"));
        QVERIFY(spy.at(0).at(0).toLongLong() > 0); // pruned bytes
    }

    void requestCacheGc_reportsPrunedAndEvictedBytesSeparately() {
        const QString fixture = rendererCacheFixture();
        QVERIFY(! fixture.isEmpty());
        const QString thumbDir = fixture + "/video-thumbs";
        QDir().mkpath(thumbDir);
        struct Cleanup {
            QString p;
            ~Cleanup() { QDir(p).removeRecursively(); }
        } cu { fixture };

        // One orphan thumbnail (prune) plus an aged 1 MiB blob (quota).
        QVERIFY(writeBytes(thumbDir + "/abc.jpg", 4096));
        QFile am(thumbDir + "/abc.meta");
        QVERIFY(am.open(QIODevice::WriteOnly));
        am.write(QJsonDocument(QJsonObject { { "src", "/nonexistent.mp4" } })
                     .toJson(QJsonDocument::Compact));
        am.close();
        QVERIFY(writeBytes(fixture + "/old.spvs", 1024 * 1024));
        QFile of(fixture + "/old.spvs");
        QVERIFY(of.open(QIODevice::ReadWrite));
        QVERIFY(
            of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileModificationTime));
        QVERIFY(of.setFileTime(QDateTime::currentDateTime().addDays(-7), QFile::FileAccessTime));
        of.close();
        QVERIFY(writeBytes(fixture + "/new.spvs", 1024 * 1024));
        const qint64 orphanBytes =
            QFileInfo(thumbDir + "/abc.jpg").size() + QFileInfo(thumbDir + "/abc.meta").size();

        FileHelper fh;
        QSignalSpy spy(&fh, &FileHelper::cacheGcFinished);
        fh.requestCacheGc(fixture, {}, {}, static_cast<qint64>(1.5 * 1024 * 1024));
        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 60000);
        QCOMPARE(spy.at(0).at(0).toLongLong(), orphanBytes); // jpg + sidecar
        QVERIFY(spy.at(0).at(1).toLongLong() >= 1024 * 1024);
        QVERIFY(! QFile::exists(fixture + "/old.spvs"));
        QVERIFY(QFile::exists(fixture + "/new.spvs"));
        QCOMPARE(fh.lastGcBytesFreed(), spy.at(0).at(1).toLongLong());
    }

    // ── generateThumbnail sidecar emission ───────────────────────────────────
    void generateThumbnail_writesSidecarForExisting() {
        QTemporaryDir cache;
        QVERIFY(cache.isValid());
        // Pre-create a stub JPEG and verify a missing sidecar is written on
        // the short-circuit (exists-and-non-empty) branch.
        const QString out = cache.path() + "/abc.jpg";
        QVERIFY(writeBytes(out, 16));
        const QString sidecar = cache.path() + "/abc.meta";
        QVERIFY(! QFile::exists(sidecar)); // pre-feature state

        FileHelper fh;
        QSignalSpy spy(&fh, &FileHelper::thumbnailReady);
        fh.generateThumbnail("/path/to/source.mp4", out, 0.5);
        QVERIFY(spy.wait(2000));
        QVERIFY(QFile::exists(sidecar));
        QFile s(sidecar);
        QVERIFY(s.open(QIODevice::ReadOnly));
        const QJsonDocument doc = QJsonDocument::fromJson(s.readAll());
        QVERIFY(doc.isObject());
        QCOMPARE(doc.object().value("src").toString(), QString("/path/to/source.mp4"));
    }

    // ── readWorkshopManifest (Valve KVFormat) ────────────────────────────────
    void readWorkshopManifest_parsesValveKV() {
        QTemporaryDir lib;
        QVERIFY(lib.isValid());
        const QString acfPath = lib.path() + "/steamapps/workshop/appworkshop_431960.acf";
        QDir().mkpath(QFileInfo(acfPath).absolutePath());
        QFile f(acfPath);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"("AppWorkshop"
{
    "appid"  "431960"
    "WorkshopItemsInstalled"
    {
        "2866203962"
        {
            "size"          "12345678"
            "timeupdated"   "1721398765"
        }
        "3363252053"
        {
            "size"          "9876543"
            "timeupdated"   "1735000000"
        }
        "3453251764"
        {
            "size"          "55"
        }
    }
}
)");
        f.close();
        FileHelper fh;
        const auto m = fh.readWorkshopManifest(lib.path());
        QCOMPARE(m.size(), 3);
        QCOMPARE(m.value("2866203962").toLongLong(), qint64 { 1721398765 });
        QCOMPARE(m.value("3363252053").toLongLong(), qint64 { 1735000000 });
        // Missing timeupdated -> 0
        QCOMPARE(m.value("3453251764").toLongLong(), qint64 { 0 });
    }

    void readWorkshopManifest_failsoftOnMalformed() {
        QTemporaryDir lib;
        QVERIFY(lib.isValid());
        const QString acfPath = lib.path() + "/steamapps/workshop/appworkshop_431960.acf";
        QDir().mkpath(QFileInfo(acfPath).absolutePath());
        QFile f(acfPath);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"("AppWorkshop"
{
    "appid"  "431960"
    "WorkshopItemsInstalled"
    {
        "broken)");
        f.close();
        FileHelper fh;
        const auto m = fh.readWorkshopManifest(lib.path());
        QVERIFY(m.isEmpty());
    }

    void readWorkshopManifest_returnsEmptyOnMissingFile() {
        FileHelper fh;
        QVERIFY(fh.readWorkshopManifest("/nonexistent/library").isEmpty());
    }

    void readWorkshopManifest_returnsEmptyOnEmptyInput() {
        FileHelper fh;
        QVERIFY(fh.readWorkshopManifest(QString()).isEmpty());
    }

    void readWorkshopManifest_stripsFileUri() {
        QTemporaryDir lib;
        QVERIFY(lib.isValid());
        const QString acfPath = lib.path() + "/steamapps/workshop/appworkshop_431960.acf";
        QDir().mkpath(QFileInfo(acfPath).absolutePath());
        QFile f(acfPath);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"("AppWorkshop" { "WorkshopItemsInstalled" { "42" { "timeupdated" "100" } } })");
        f.close();
        FileHelper fh;
        const auto m = fh.readWorkshopManifest("file://" + lib.path());
        QCOMPARE(m.size(), 1);
        QCOMPARE(m.value("42").toLongLong(), qint64 { 100 });
    }

    // ── recordSeenVersion / seenVersion ──────────────────────────────────────
    void recordSeenVersion_writesBackToIdJson() {
        // Use isolated config dir under the test-mode QStandardPaths.
        const QString cfg =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        QDir().mkpath(cfg);
        QFile pre(cfg + "/123.json");
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write(R"({"display_mode": 1})");
        pre.close();

        FileHelper fh;
        fh.recordSeenVersion("123", 1721398765);

        QFile post(cfg + "/123.json");
        QVERIFY(post.open(QIODevice::ReadOnly));
        const QJsonDocument d = QJsonDocument::fromJson(post.readAll());
        QVERIFY(d.isObject());
        QCOMPARE(d.object().value("display_mode").toInt(), 1);
        QCOMPARE(d.object().value("last_seen_version").toVariant().toLongLong(),
                 qint64 { 1721398765 });
    }

    void recordSeenVersion_createsFileWhenAbsent() {
        const QString cfg =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        QDir().mkpath(cfg);
        // Make sure file doesn't exist yet.
        QFile::remove(cfg + "/456.json");

        FileHelper fh;
        fh.recordSeenVersion("456", 12345);

        QFile post(cfg + "/456.json");
        QVERIFY(post.exists());
        QVERIFY(post.open(QIODevice::ReadOnly));
        const QJsonDocument d = QJsonDocument::fromJson(post.readAll());
        QVERIFY(d.isObject());
        QCOMPARE(d.object().value("last_seen_version").toVariant().toLongLong(), qint64 { 12345 });
    }

    void seenVersion_returnsZeroWhenKeyAbsent() {
        const QString cfg =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        QDir().mkpath(cfg);
        QFile pre(cfg + "/789.json");
        QVERIFY(pre.open(QIODevice::WriteOnly));
        pre.write(R"({"display_mode": 1})");
        pre.close();

        FileHelper fh;
        QCOMPARE(fh.seenVersion("789"), qint64 { 0 });
    }

    void seenVersion_returnsZeroWhenFileAbsent() {
        FileHelper fh;
        QCOMPARE(fh.seenVersion("doesnotexist"), qint64 { 0 });
    }

    void recordSeenVersion_idempotent() {
        const QString cfg =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        QDir().mkpath(cfg);
        QFile::remove(cfg + "/idemp.json");
        FileHelper fh;
        fh.recordSeenVersion("idemp", 42);
        fh.recordSeenVersion("idemp", 42);
        QCOMPARE(fh.seenVersion("idemp"), qint64 { 42 });
    }

    void allSeenVersions_returnsMap() {
        const QString cfg =
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
            "/wekde/wallpaper";
        // Clean slate first — prior tests leave files behind in the same
        // test-mode config dir.
        QDir(cfg).removeRecursively();
        QDir().mkpath(cfg);

        FileHelper fh;
        fh.recordSeenVersion("aaa", 100);
        fh.recordSeenVersion("bbb", 200);
        QFile noVer(cfg + "/ccc.json");
        QVERIFY(noVer.open(QIODevice::WriteOnly));
        noVer.write(R"({"display_mode": 1})");
        noVer.close();

        const auto m = fh.allSeenVersions();
        QCOMPARE(m.size(), 2);
        QCOMPARE(m.value("aaa").toLongLong(), qint64 { 100 });
        QCOMPARE(m.value("bbb").toLongLong(), qint64 { 200 });
        QVERIFY(! m.contains("ccc"));
    }
};

QTEST_MAIN(TestFileHelper)
#include "tst_filehelper.moc"
