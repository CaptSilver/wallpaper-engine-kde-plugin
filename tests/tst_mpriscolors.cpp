#include <QtTest>
#include <QImage>
#include <QColor>
#include <QVariantList>
#include "MprisMonitor.hpp"

class TestMprisColors : public QObject {
    Q_OBJECT

private slots:
    void solidRedImage();
    void solidBlueImage();
    void blackImage();
    void whiteImage();
    void twoColorImage();
    void returnsExactly15Floats();
    void valuesInZeroOneRange();
    void textColorBlackForBrightImage();
    void textColorWhiteForDarkImage();
    void highContrastDiffersFromPrimary();
    void singlePixelImage();
    void largeImage();
};

// Helper: create a solid-color image
static QImage solidImage(QColor color, int size = 32) {
    QImage img(size, size, QImage::Format_RGB32);
    img.fill(color);
    return img;
}

void TestMprisColors::solidRedImage() {
    QVariantList colors = wekde::extractDominantColors(solidImage(Qt::red));
    QCOMPARE(colors.size(), 15);
    // Primary should be close to (1, 0, 0)
    QVERIFY(colors[0].toDouble() > 0.8);  // R
    QVERIFY(colors[1].toDouble() < 0.2);  // G
    QVERIFY(colors[2].toDouble() < 0.2);  // B
}

void TestMprisColors::solidBlueImage() {
    QVariantList colors = wekde::extractDominantColors(solidImage(Qt::blue));
    QCOMPARE(colors.size(), 15);
    QVERIFY(colors[0].toDouble() < 0.2);  // R
    QVERIFY(colors[1].toDouble() < 0.2);  // G
    QVERIFY(colors[2].toDouble() > 0.8);  // B
}

void TestMprisColors::blackImage() {
    QVariantList colors = wekde::extractDominantColors(solidImage(Qt::black));
    QCOMPARE(colors.size(), 15);
    // Primary close to (0,0,0)
    QVERIFY(colors[0].toDouble() < 0.1);
    QVERIFY(colors[1].toDouble() < 0.1);
    QVERIFY(colors[2].toDouble() < 0.1);
    // Text color should be white for dark image
    QVERIFY(colors[9].toDouble() > 0.9);  // text R
    QVERIFY(colors[10].toDouble() > 0.9); // text G
    QVERIFY(colors[11].toDouble() > 0.9); // text B
}

void TestMprisColors::whiteImage() {
    QVariantList colors = wekde::extractDominantColors(solidImage(Qt::white));
    QCOMPARE(colors.size(), 15);
    // Text color should be black for bright image
    QVERIFY(colors[9].toDouble() < 0.1);  // text R
    QVERIFY(colors[10].toDouble() < 0.1);
    QVERIFY(colors[11].toDouble() < 0.1);
}

void TestMprisColors::twoColorImage() {
    // Left half red, right half blue
    QImage img(32, 32, QImage::Format_RGB32);
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 32; x++) {
            img.setPixelColor(x, y, x < 16 ? Qt::red : Qt::blue);
        }
    }
    QVariantList colors = wekde::extractDominantColors(img);
    QCOMPARE(colors.size(), 15);
    // Primary and secondary should be different
    double pr = colors[0].toDouble(), pg = colors[1].toDouble(), pb = colors[2].toDouble();
    double sr = colors[3].toDouble(), sg = colors[4].toDouble(), sb = colors[5].toDouble();
    double diff = std::abs(pr - sr) + std::abs(pg - sg) + std::abs(pb - sb);
    QVERIFY(diff > 0.5); // colors should be significantly different
}

void TestMprisColors::returnsExactly15Floats() {
    QVariantList colors = wekde::extractDominantColors(solidImage(QColor(128, 64, 32)));
    QCOMPARE(colors.size(), 15);
}

void TestMprisColors::valuesInZeroOneRange() {
    QImage img(64, 64, QImage::Format_RGB32);
    // Random-ish gradient
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 64; x++)
            img.setPixelColor(x, y, QColor(x * 4, y * 4, (x + y) * 2));
    QVariantList colors = wekde::extractDominantColors(img);
    for (int i = 0; i < colors.size(); i++) {
        double v = colors[i].toDouble();
        QVERIFY2(v >= 0.0 && v <= 1.0,
                 qPrintable(QString("color[%1] = %2 out of range").arg(i).arg(v)));
    }
}

void TestMprisColors::textColorBlackForBrightImage() {
    QVariantList colors = wekde::extractDominantColors(solidImage(QColor(255, 255, 200)));
    // Bright yellow → text should be black
    QVERIFY(colors[9].toDouble() < 0.1);
}

void TestMprisColors::textColorWhiteForDarkImage() {
    QVariantList colors = wekde::extractDominantColors(solidImage(QColor(20, 10, 30)));
    // Dark purple → text should be white
    QVERIFY(colors[9].toDouble() > 0.9);
}

void TestMprisColors::highContrastDiffersFromPrimary() {
    // Half red, half cyan — high contrast should be very different from primary
    QImage img(32, 32, QImage::Format_RGB32);
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++)
            img.setPixelColor(x, y, y < 16 ? QColor(255, 0, 0) : QColor(0, 255, 255));
    QVariantList colors = wekde::extractDominantColors(img);
    double pr = colors[0].toDouble(), pg = colors[1].toDouble(), pb = colors[2].toDouble();
    double cr = colors[12].toDouble(), cg = colors[13].toDouble(), cb = colors[14].toDouble();
    double dist = std::sqrt((pr-cr)*(pr-cr) + (pg-cg)*(pg-cg) + (pb-cb)*(pb-cb));
    QVERIFY(dist > 0.5);
}

void TestMprisColors::singlePixelImage() {
    QImage img(1, 1, QImage::Format_RGB32);
    img.setPixelColor(0, 0, QColor(100, 200, 50));
    QVariantList colors = wekde::extractDominantColors(img);
    QCOMPARE(colors.size(), 15);
    // Should not crash and should return valid colors
    QVERIFY(colors[0].toDouble() >= 0.0);
}

void TestMprisColors::largeImage() {
    // 1024x1024 — should still work (gets scaled to 16x16 internally)
    QImage img(1024, 1024, QImage::Format_RGB32);
    img.fill(QColor(50, 100, 200));
    QVariantList colors = wekde::extractDominantColors(img);
    QCOMPARE(colors.size(), 15);
    QVERIFY(colors[2].toDouble() > 0.5); // B should be dominant
}

QTEST_GUILESS_MAIN(TestMprisColors)
#include "tst_mpriscolors.moc"
