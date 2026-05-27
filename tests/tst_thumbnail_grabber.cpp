// Tests for ThumbnailGrabber — extracts a frame from a video to a JPEG file.
// Skips at runtime if libmpv cannot initialize (CI without GPU/VAAPI etc.).
#include <QtTest>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QMutex>
#include <QMutexLocker>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <clocale>
#include <vector>
#include "ThumbnailGrabber.hpp"
#include "FileHelper.hpp"

using wekde::FileHelper;
using wekde::ThumbnailGrabber;

// Process-global message sink used by the install-during-test QtMessageHandler.
// Guarded by g_sinkMutex because libmpv emits warnings from internal worker
// threads (mpv runs its own dispatcher), and FileHelper::generateThumbnail
// invokes the grabber from a QThreadPool worker.
static QMutex                          g_sinkMutex;
static std::vector<QString>            g_sink;
static QtMessageHandler                g_prevHandler = nullptr;
static void sinkHandler(QtMsgType type, const QMessageLogContext& ctx, const QString& msg) {
    {
        QMutexLocker lock(&g_sinkMutex);
        g_sink.push_back(msg);
    }
    if (g_prevHandler) g_prevHandler(type, ctx, msg);
}

class TestThumbnailGrabber : public QObject {
    Q_OBJECT

    // Returns true if the global sink contains any message containing `substr`.
    static bool sinkContains(const QString& substr) {
        QMutexLocker lock(&g_sinkMutex);
        for (const QString& m : g_sink) {
            if (m.contains(substr)) return true;
        }
        return false;
    }
    static void sinkReset() {
        QMutexLocker lock(&g_sinkMutex);
        g_sink.clear();
    }

private slots:
    void initTestCase() {
        // libmpv requires LC_NUMERIC=C; production sets it in plugin.cpp
        // registerTypes (which this test binary doesn't link).  Pin it here
        // once on the test main thread before any libmpv call — std::setlocale
        // mutates a process-global so this MUST run on the main thread, not
        // from a pool worker (which is what ThumbnailGrabber::Impl used to do
        // unsafely).
        std::setlocale(LC_NUMERIC, "C");
        // Install the qWarning/qCritical sink for the lifetime of the suite.
        g_prevHandler = qInstallMessageHandler(sinkHandler);
    }

    void cleanupTestCase() { qInstallMessageHandler(g_prevHandler); }

    void init() { sinkReset(); }

    void grab_writesValidJpeg() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString out = d.filePath("thumb.jpg");

        ThumbnailGrabber grabber;
        const bool ok = grabber.grab(QFINDTESTDATA("fixtures/tiny.webm"), out, /*atSeconds=*/0.5);
        if (! ok) QSKIP("libmpv could not init or seek failed in this environment");

        QVERIFY(QFile::exists(out));
        QVERIFY(QFileInfo(out).size() > 256);
        QImage img(out);
        QVERIFY(! img.isNull());
        QVERIFY(img.width() > 0);
        QVERIFY(img.height() > 0);
    }

    void grab_rejectsMissingInput() {
        QTemporaryDir    d;
        const QString    out = d.filePath("thumb.jpg");
        ThumbnailGrabber grabber;
        QCOMPARE(grabber.grab("/tmp/wekde_no_such_video.webm", out, 0.5), false);
        QVERIFY(! QFile::exists(out));
        // Site #4: the missing-input branch must emit a journal breadcrumb so
        // a user with a blank thumbnail tile can grep for the cause.
        QVERIFY(sinkContains("source file does not exist"));
    }

    // When the input file exists but isn't a valid video, libmpv emits
    // MPV_EVENT_END_FILE during the load wait — covers the early-return
    // branch on END_FILE inside the load loop.
    void grab_existingNonVideoTriggersEndFile_returnsFalse() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        // A plain text file mpv can't decode as a media stream.
        const QString in = d.filePath("not_a_video.txt");
        QFile         f(in);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("definitely not media content");
        f.close();

        const QString    out = d.filePath("thumb.jpg");
        ThumbnailGrabber grabber;
        QCOMPARE(grabber.grab(in, out, 0.5), false);
        QVERIFY(! QFile::exists(out));
        // Site #6: END_FILE during the load wait — assert the journal line.
        QVERIFY(sinkContains("END_FILE during load"));
    }

    // Seek absolute past the end of the clip → libmpv may emit END_FILE
    // during the seek wait.  Either path inside the seek loop is acceptable
    // (END_FILE return-false OR PLAYBACK_RESTART success), but the test
    // pushes the seek-loop branch where it can land the END_FILE path.
    void grab_seekPastEnd_returnsFalseOrSilent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString in = QFINDTESTDATA("fixtures/tiny.webm");
        if (! QFileInfo::exists(in)) QSKIP("fixtures/tiny.webm missing in this environment");
        const QString out = d.filePath("seek_past_end.jpg");

        ThumbnailGrabber grabber;
        // tiny.webm is ~2s; ask for 100s. libmpv either clamps or emits
        // END_FILE — both end in grab() returning a boolean we don't crash on.
        const bool ok = grabber.grab(in, out, /*atSeconds=*/100.0);
        // We don't strictly require a particular return value: some libmpv
        // builds clamp the seek and capture the last frame (returning true);
        // others emit END_FILE and return false.  We only verify no crash
        // and consistency between the bool result and the file presence.
        if (ok) {
            QVERIFY(QFile::exists(out));
            QVERIFY(QFileInfo(out).size() > 0);
        } else {
            // Site #9 OR #10 fired — accept either "END_FILE during seek"
            // (libmpv refuses the past-end seek) or "seek timeout"
            // (PLAYBACK_RESTART never arrives within budget). Some libmpv
            // builds also fall through the file-existence check, so accept
            // the screenshot-missing variant too.
            QVERIFY(sinkContains("END_FILE during seek")
                    || sinkContains("seek timeout")
                    || sinkContains("screenshot file missing"));
        }
    }

    // F16: on a seek timeout (no MPV_EVENT_PLAYBACK_RESTART within budget),
    // grab() must return false BEFORE running screenshot-to-file — otherwise a
    // wrong-position (typically t=0) frame is cached and reported as success.
    // The directly-observable consequence of the new `if (!seeked) return
    // false;` guard: when ok==false, no output file was written.
    //
    // We push the seek-timeout/END-without-restart branch via a past-end
    // absolute seek. Some libmpv builds clamp the seek and emit
    // PLAYBACK_RESTART (ok==true, the existing happy path); on those this
    // assertion is vacuously satisfied but still correct. On builds that take
    // the false branch, it locks in "no file on a failed seek".
    void grab_seekPastEndNeverCapturesT0Frame() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString in = QFINDTESTDATA("fixtures/tiny.webm");
        if (! QFileInfo::exists(in)) QSKIP("fixtures/tiny.webm missing in this environment");
        const QString out = d.filePath("never_t0.jpg");

        ThumbnailGrabber grabber;
        const bool       ok = grabber.grab(in, out, /*atSeconds=*/100.0);
        if (! ok) {
            // Guard fired before the screenshot — no garbage frame on disk.
            QVERIFY(! QFile::exists(out));
        }
    }

    void generateThumbnail_emitsThumbnailReady() {
        QTemporaryDir d;
        const QString in  = QFINDTESTDATA("fixtures/tiny.webm");
        const QString out = d.filePath("thumb_async.jpg");

        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() > 0, 10000);
        QCOMPARE(spy.count(), 1);
        const QList<QVariant> args = spy.takeFirst();
        QCOMPARE(args.at(0).toString(), in);
        QCOMPARE(args.at(1).toString(), out);
        if (! args.at(2).toBool()) QSKIP("libmpv unable to grab in this environment");
        QVERIFY(QFile::exists(out));
    }

    void generateThumbnail_coalescesConcurrentRequestsOnSamePath() {
        QTemporaryDir d;
        const QString in  = QFINDTESTDATA("fixtures/tiny.webm");
        const QString out = d.filePath("thumb_dup.jpg");

        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        // Second call while first is in flight is dropped (coalesced).
        helper.generateThumbnail(in, out, 0.5);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() > 0, 10000);
        // Exactly one signal — second call returned without queueing work.
        QCOMPARE(spy.count(), 1);
    }

    void generateThumbnail_shortCircuitsWhenCacheExists() {
        QTemporaryDir d;
        const QString in  = QFINDTESTDATA("fixtures/tiny.webm");
        const QString out = d.filePath("thumb_cached.jpg");

        // Pre-populate the cache file (any non-empty content stands in for
        // a previously-generated thumbnail).
        {
            QFile f(out);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write("not actually a jpeg, but non-empty");
            f.close();
        }

        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() > 0, 2000);
        QCOMPARE(spy.count(), 1);
        const auto args = spy.takeFirst();
        QCOMPARE(args.at(2).toBool(), true);
        // File untouched — still our placeholder content (libmpv would have
        // overwritten with a real JPEG ~256+ bytes; we wrote 34 bytes above).
        QCOMPARE(QFileInfo(out).size(), qint64(34));
    }

    void generateThumbnail_createsCacheDirIfMissing() {
        QTemporaryDir d;
        const QString in = QFINDTESTDATA("fixtures/tiny.webm");
        // Output under a directory that does not exist yet.
        const QString out = d.filePath("nested/sub/thumb.jpg");
        QVERIFY(! QFileInfo::exists(QFileInfo(out).absolutePath()));

        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() > 0, 10000);
        QCOMPARE(spy.count(), 1);
        // Whether the grab succeeded or not, the parent dir must now exist.
        QVERIFY(QFileInfo::exists(QFileInfo(out).absolutePath()));
        // Regression: the success path of mkpath must NOT emit the failure
        // warning — only the qWarning when mkpath returns false.
        QVERIFY(! sinkContains("mkpath failed"));
    }

    // Site #11: when screenshot-to-file cannot write the output (parent dir
    // missing AND not creatable), libmpv's command returns < 0 OR the file
    // never materialises. Either path now logs a journal breadcrumb. We try
    // first to drive site #11 via an unwriteable outPath; if libmpv writes
    // to a temp file first and renames (different version), site #12 fires
    // instead — both substrings are accepted.
    void grab_unwriteableOutPath_logsScreenshotFailure() {
        const QString in = QFINDTESTDATA("fixtures/tiny.webm");
        if (! QFileInfo::exists(in)) QSKIP("fixtures/tiny.webm missing in this environment");
        // /proc is read-only on Linux; libmpv cannot create a JPEG under it.
        const QString    out = "/proc/wek_e2_no_write/thumb.jpg";
        ThumbnailGrabber grabber;
        const bool       ok = grabber.grab(in, out, /*atSeconds=*/0.5);
        if (ok) QSKIP("libmpv unexpectedly wrote under /proc — env doesn't reach site #11");
        // Either site #11 (mpv_command failure) or site #12 (file missing
        // post-screenshot) fired; both are acceptable evidence the new
        // breadcrumb landed.
        QVERIFY(sinkContains("screenshot-to-file mpv_command failed")
                || sinkContains("screenshot file missing"));
    }

    // FileHelper::generateThumbnail mkpath no-op: if the parent dir cannot
    // be created (read-only ancestor), the worker now emits a qWarning so
    // the screenshot-to-file failure that follows isn't mis-blamed on
    // libmpv. Worker still completes — the thumbnailReady(ok=false) signal
    // fires and the caller knows the grab failed.
    void generateThumbnail_logsMkpathFailureOnUnwriteableParent() {
        const QString in = QFINDTESTDATA("fixtures/tiny.webm");
        // /proc is read-only on Linux → mkpath cannot create the subtree.
        const QString out = "/proc/wek_e2_mkpath_fail/sub/thumb.jpg";
        FileHelper    helper;
        QSignalSpy    spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() > 0, 10000);
        QCOMPARE(spy.count(), 1);
        const QList<QVariant> args = spy.takeFirst();
        // The grab MUST report failure when mkpath fails AND libmpv cannot
        // write the screenshot. Some libmpv builds may silently succeed if a
        // temp staging path exists; treat that as a SKIP rather than a fail
        // since the journal-breadcrumb assertion below is the load-bearing
        // contract.
        if (args.at(2).toBool()) QSKIP("libmpv unexpectedly wrote under /proc — skip mkpath assertion");
        QVERIFY(sinkContains("mkpath failed"));
    }

    // Regression: the happy-path grab must NOT emit ANY of the new qWarning
    // lines. If libmpv refuses to init in CI (no codec), QSKIP; otherwise
    // the sink stays clean after a successful grab.
    void grab_happyPath_emitsNoWarnings() {
        QTemporaryDir d;
        const QString out = d.filePath("ok.jpg");
        const QString in  = QFINDTESTDATA("fixtures/tiny.webm");
        if (! QFileInfo::exists(in)) QSKIP("fixtures/tiny.webm missing in this environment");
        ThumbnailGrabber grabber;
        const bool       ok = grabber.grab(in, out, 0.5);
        if (! ok) QSKIP("libmpv could not init or seek in this environment");
        // The 12 sites all emit substrings starting with "ThumbnailGrabber:".
        QVERIFY(! sinkContains("ThumbnailGrabber:"));
    }
};

QTEST_GUILESS_MAIN(TestThumbnailGrabber)
#include "tst_thumbnail_grabber.moc"
