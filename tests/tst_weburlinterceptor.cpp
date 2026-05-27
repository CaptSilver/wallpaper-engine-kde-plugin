#include <QtTest/QtTest>
#include <QTemporaryDir>
#include <QFile>
#include <QDir>
#include "WebUrlInterceptor.hpp"

class TestWebUrlInterceptor : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QVERIFY(m_dir.isValid());
        m_base = QFileInfo(m_dir.path()).canonicalFilePath();
        QDir(m_base).mkpath("sub");
        QFile f(m_base + "/index.html");
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("<html></html>");
        QFile g(m_base + "/sub/a.js");
        QVERIFY(g.open(QIODevice::WriteOnly));
        g.write("// js");
    }

    void isAllowed_underBase_allowed() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(it.isAllowed(QUrl::fromLocalFile(m_base + "/index.html")));
        QVERIFY(it.isAllowed(QUrl::fromLocalFile(m_base + "/sub/a.js")));
    }

    void isAllowed_blocksSiblingPrefix() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        // /tmp/wp-evil/x has the canonical-base as a literal prefix without
        // the boundary slash → must NOT pass.
        const QString siblingDir = QFileInfo(m_base).absolutePath() + "/wp-evil";
        QDir(QFileInfo(m_base).absolutePath()).mkpath("wp-evil");
        QFile f(siblingDir + "/x");
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("nope");
        f.close();
        QVERIFY(! it.isAllowed(QUrl::fromLocalFile(siblingDir + "/x")));
    }

    void isAllowed_blocksOutsideHome() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(! it.isAllowed(QUrl::fromLocalFile("/etc/passwd")));
    }

    void isAllowed_allowsNonFileSchemes() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(it.isAllowed(QUrl("https://fonts.googleapis.com/css?family=Roboto")));
        QVERIFY(it.isAllowed(QUrl("http://example.com/")));
        QVERIFY(it.isAllowed(QUrl("data:image/png;base64,AAA=")));
        QVERIFY(it.isAllowed(QUrl("blob:https://example.com/abc")));
        QVERIFY(it.isAllowed(QUrl("qrc:/qtwebchannel/qwebchannel.js")));
    }

    void isAllowed_symlinkEscape_blocked() {
        // Symlink inside the wallpaper pointing at /etc/passwd: canonicalFilePath
        // resolves to outside the base, so the predicate must refuse.
        const QString link = m_base + "/escape";
        QFile::remove(link); // idempotent
        QVERIFY(QFile::link("/etc/passwd", link));
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(! it.isAllowed(QUrl::fromLocalFile(link)));
        QFile::remove(link);
    }

    void isAllowed_pathTraversal_blocked() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(! it.isAllowed(QUrl::fromLocalFile(m_base + "/../../../etc/passwd")));
        const QUrl encoded(QString("file://") + m_base + "/%2e%2e/etc/passwd");
        QVERIFY(! it.isAllowed(encoded));
    }

    void isAllowed_noBaseSet_blocksFileButAllowsHttps() {
        wekde::WebUrlInterceptor it; // setWallpaperBaseDir never called
        QVERIFY(! it.isAllowed(QUrl::fromLocalFile("/tmp/anything")));
        QVERIFY(it.isAllowed(QUrl("https://example.com/")));
    }

    void isAllowed_emptyBaseReset_blocksAgain() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(it.isAllowed(QUrl::fromLocalFile(m_base + "/index.html")));
        it.setWallpaperBaseDir(QString());
        QVERIFY(! it.isAllowed(QUrl::fromLocalFile(m_base + "/index.html")));
    }

    void isAllowed_baseItself_allowed() {
        wekde::WebUrlInterceptor it;
        it.setWallpaperBaseDir(m_base);
        QVERIFY(it.isAllowed(QUrl::fromLocalFile(m_base)));
    }

private:
    QTemporaryDir m_dir;
    QString       m_base;
};

QTEST_MAIN(TestWebUrlInterceptor)
#include "tst_weburlinterceptor.moc"
