// Fast ownership check for the fixture tree tst_main_integration builds.
// Stands in for the slow ASAN sanitizer leg as the everyday signal that the
// FakeContainment/FakeWallpaperItem leak stays fixed.
#include <QObject>
#include <QQuickItem>
#include <QTest>

#include "FakeWallpaper.h"

class TstFakeWallpaperOwnership : public QObject {
    Q_OBJECT
private slots:
    void ownershipTree_isRootedAtTheGivenOwner() {
        QObject owner;
        auto*   wallpaper = buildOwnedFakeWallpaperTree(&owner);
        QVERIFY(wallpaper->parentItem() != nullptr);
        QCOMPARE(wallpaper->parent(), &owner);
        QCOMPARE(wallpaper->parentItem()->parent(), &owner);
    }
};

QTEST_GUILESS_MAIN(TstFakeWallpaperOwnership)
#include "tst_fakewallpaper_ownership.moc"
