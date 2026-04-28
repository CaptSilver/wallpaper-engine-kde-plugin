// Tests for ThumbnailGrabber — extracts a frame from a video to a JPEG file.
// Skips at runtime if libmpv cannot initialize (CI without GPU/VAAPI etc.).
#include <QtTest>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QSignalSpy>
#include <QTemporaryDir>
#include "ThumbnailGrabber.hpp"
#include "FileHelper.hpp"

using wekde::ThumbnailGrabber;
using wekde::FileHelper;

class TestThumbnailGrabber : public QObject {
    Q_OBJECT

private slots:

    void grab_writesValidJpeg() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString out = d.filePath("thumb.jpg");

        ThumbnailGrabber grabber;
        const bool ok = grabber.grab(
            QFINDTESTDATA("fixtures/tiny.webm"), out, /*atSeconds=*/0.5);
        if (! ok) QSKIP("libmpv could not init or seek failed in this environment");

        QVERIFY(QFile::exists(out));
        QVERIFY(QFileInfo(out).size() > 256);
        QImage img(out);
        QVERIFY(! img.isNull());
        QVERIFY(img.width()  > 0);
        QVERIFY(img.height() > 0);
    }

    void grab_rejectsMissingInput() {
        QTemporaryDir d;
        const QString out = d.filePath("thumb.jpg");
        ThumbnailGrabber grabber;
        QCOMPARE(grabber.grab("/tmp/wekde_no_such_video.webm", out, 0.5), false);
        QVERIFY(! QFile::exists(out));
    }

    void generateThumbnail_emitsThumbnailReady() {
        QTemporaryDir d;
        const QString in  = QFINDTESTDATA("fixtures/tiny.webm");
        const QString out = d.filePath("thumb_async.jpg");

        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        QVERIFY(spy.wait(10000));
        QCOMPARE(spy.count(), 1);
        const QList<QVariant> args = spy.takeFirst();
        QCOMPARE(args.at(0).toString(), in);
        QCOMPARE(args.at(1).toString(), out);
        if (! args.at(2).toBool())
            QSKIP("libmpv unable to grab in this environment");
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
        QVERIFY(spy.wait(10000));
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
        QVERIFY(spy.wait(2000));
        QCOMPARE(spy.count(), 1);
        const auto args = spy.takeFirst();
        QCOMPARE(args.at(2).toBool(), true);
        // File untouched — still our placeholder content (libmpv would have
        // overwritten with a real JPEG ~256+ bytes; we wrote 34 bytes above).
        QCOMPARE(QFileInfo(out).size(), qint64(34));
    }

    void generateThumbnail_createsCacheDirIfMissing() {
        QTemporaryDir d;
        const QString in  = QFINDTESTDATA("fixtures/tiny.webm");
        // Output under a directory that does not exist yet.
        const QString out = d.filePath("nested/sub/thumb.jpg");
        QVERIFY(! QFileInfo::exists(QFileInfo(out).absolutePath()));

        FileHelper helper;
        QSignalSpy spy(&helper, &FileHelper::thumbnailReady);
        helper.generateThumbnail(in, out, 0.5);
        QVERIFY(spy.wait(10000));
        QCOMPARE(spy.count(), 1);
        // Whether the grab succeeded or not, the parent dir must now exist.
        QVERIFY(QFileInfo::exists(QFileInfo(out).absolutePath()));
    }
};

QTEST_GUILESS_MAIN(TestThumbnailGrabber)
#include "tst_thumbnail_grabber.moc"
