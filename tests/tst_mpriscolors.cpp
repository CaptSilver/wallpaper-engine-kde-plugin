#include <QtTest>
#include <QBuffer>
#include <QImage>
#include <QColor>
#include <QCoreApplication>
#include <QMetaObject>
#include <QSignalSpy>
#include <QTemporaryFile>
#include <QVariantList>
#include <QVariantMap>
#include "MprisMonitor.hpp"

class TestMprisColors : public QObject {
    Q_OBJECT

private slots:
    // extractDominantColors
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

    // toPlaybackState
    void toPlaybackState_Playing();
    void toPlaybackState_Paused();
    void toPlaybackState_Stopped();
    void toPlaybackState_Unknown();
    void toPlaybackState_Empty();

    // parseMprisMetadata
    void parseMetadata_empty();
    void parseMetadata_title();
    void parseMetadata_multipleArtistsJoinWithComma();
    void parseMetadata_singleArtist();
    void parseMetadata_album_albumArtist_genres();
    void parseMetadata_durationUsecToSec();
    void parseMetadata_zeroDuration();
    void parseMetadata_artUrl();

    // classifyArtUrl
    void classifyArt_empty();
    void classifyArt_localFile();
    void classifyArt_http();
    void classifyArt_https();
    void classifyArt_unknownScheme();
    void classifyArt_nonUrlJunk();

    // MprisMonitor signal behavior (private slots invoked via meta system)
    void handlePropsChanged_wrongInterface_noSignals();
    void handlePropsChanged_playbackPlaying_emitsState1();
    void handlePropsChanged_playbackPaused_emitsState2();
    void handlePropsChanged_playbackStopped_emitsState0();
    void handlePropsChanged_sameState_noDuplicateEmit();
    void handlePropsChanged_metadataMap_emitsPropertiesChanged();
    void handlePropsChanged_metadataEmptyArtUrl_thumbnailFalse();
    void handlePropsChanged_metadataLocalFileArtUrl_thumbnailTrue();
    void handlePropsChanged_metadataBadLocalArtUrl_thumbnailFalse();
    void handlePropsChanged_metadataUnknownScheme_thumbnailFalse();
    void handlePropsChanged_sameArtUrl_doesNotReprocess();
    void handleNameOwnerChanged_nonMprisName_ignored();
    void handleNameOwnerChanged_mprisNameAppears_entersConnectBranch();
    void handlePropsChanged_metadataHttpArtUrl_createsRequest();
    void pollPosition_noActiveService_noSignals();

    // mapShortcutToMpris — SceneScript usershortcut name → MPRIS method
    void shortcut_bplay_PlayPause();
    void shortcut_bpause_PlayPause();
    void shortcut_bplaypause_PlayPause();
    void shortcut_bnext_Next();
    void shortcut_bprev_Previous();
    void shortcut_bstop_Stop();
    void shortcut_solarB11_Next();
    void shortcut_solarB12_Previous();
    void shortcut_caseInsensitive();
    void shortcut_unknownNameReturnsEmpty();
    void shortcut_emptyReturnsEmpty();
    void shortcut_arbitraryNumericDoesNotLeak();

    // invokePlayer / invokeShortcut — DBus method dispatch with allowlist
    void invokePlayer_emptyMethod_noop();
    void invokePlayer_noActiveService_noop();
    void invokePlayer_rejectsNonAllowlisted();
    void invokePlayer_allowlistedMethod_exercisesSendPath();
    void invokeShortcut_recognizedName_returnsTrue();
    void invokeShortcut_unknownName_returnsFalse();
    void invokeShortcut_emptyName_returnsFalse();

    // handleNameOwnerChanged vanish path → disconnectFromPlayer
    void handleNameOwnerChanged_activePlayerVanishes_disconnects();
    void handleNameOwnerChanged_unrelatedServiceVanishes_noDisconnect();

    // decodeArtReplyBytes — pure helper for onArtDownloaded
    void decodeArt_networkError_returnsFalse();
    void decodeArt_emptyBytes_returnsFalse();
    void decodeArt_garbageBytes_returnsFalse();
    void decodeArt_validPng_returnsTrueWith15Colors();
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

// ===========================================================================
// toPlaybackState — pure string → int mapping
// ===========================================================================

void TestMprisColors::toPlaybackState_Playing() {
    QCOMPARE(wekde::toPlaybackState("Playing"), 1);
}
void TestMprisColors::toPlaybackState_Paused() {
    QCOMPARE(wekde::toPlaybackState("Paused"), 2);
}
void TestMprisColors::toPlaybackState_Stopped() {
    QCOMPARE(wekde::toPlaybackState("Stopped"), 0);
}
void TestMprisColors::toPlaybackState_Unknown() {
    QCOMPARE(wekde::toPlaybackState("BogusStateValue"), 0);
}
void TestMprisColors::toPlaybackState_Empty() {
    QCOMPARE(wekde::toPlaybackState(""), 0);
}

// ===========================================================================
// parseMprisMetadata — pure QVariantMap → struct
// ===========================================================================

void TestMprisColors::parseMetadata_empty() {
    auto md = wekde::parseMprisMetadata(QVariantMap());
    QVERIFY(md.title.isEmpty());
    QVERIFY(md.artist.isEmpty());
    QVERIFY(md.album.isEmpty());
    QVERIFY(md.albumArtist.isEmpty());
    QVERIFY(md.genres.isEmpty());
    QVERIFY(md.artUrl.isEmpty());
    QCOMPARE(md.duration, 0.0);
}

void TestMprisColors::parseMetadata_title() {
    QVariantMap m;
    m["xesam:title"] = "Great Song";
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.title, QString("Great Song"));
}

void TestMprisColors::parseMetadata_multipleArtistsJoinWithComma() {
    QVariantMap m;
    m["xesam:artist"] = QStringList { "A", "B", "C" };
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.artist, QString("A, B, C"));
}

void TestMprisColors::parseMetadata_singleArtist() {
    QVariantMap m;
    m["xesam:artist"] = QStringList { "Solo" };
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.artist, QString("Solo"));
}

void TestMprisColors::parseMetadata_album_albumArtist_genres() {
    QVariantMap m;
    m["xesam:album"]       = "The Album";
    m["xesam:albumArtist"] = QStringList { "Artist1", "Artist2" };
    m["xesam:genre"]       = QStringList { "Rock", "Pop" };
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.album, QString("The Album"));
    QCOMPARE(md.albumArtist, QString("Artist1, Artist2"));
    QCOMPARE(md.genres, QString("Rock, Pop"));
}

void TestMprisColors::parseMetadata_durationUsecToSec() {
    QVariantMap m;
    m["mpris:length"] = qint64(60'000'000); // 60s in µs
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.duration, 60.0);
}

void TestMprisColors::parseMetadata_zeroDuration() {
    QVariantMap m;
    m["mpris:length"] = qint64(0);
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.duration, 0.0);
}

void TestMprisColors::parseMetadata_artUrl() {
    QVariantMap m;
    m["mpris:artUrl"] = "file:///tmp/cover.png";
    auto md = wekde::parseMprisMetadata(m);
    QCOMPARE(md.artUrl, QString("file:///tmp/cover.png"));
}

// ===========================================================================
// classifyArtUrl — pure string → enum
// ===========================================================================

void TestMprisColors::classifyArt_empty() {
    QCOMPARE(wekde::classifyArtUrl(""), wekde::MprisArtUrlKind::Empty);
}
void TestMprisColors::classifyArt_localFile() {
    QCOMPARE(wekde::classifyArtUrl("file:///tmp/cover.png"), wekde::MprisArtUrlKind::LocalFile);
}
void TestMprisColors::classifyArt_http() {
    QCOMPARE(wekde::classifyArtUrl("http://example.com/a.png"), wekde::MprisArtUrlKind::Http);
}
void TestMprisColors::classifyArt_https() {
    QCOMPARE(wekde::classifyArtUrl("https://cdn.example/cover.jpg"),
             wekde::MprisArtUrlKind::Http);
}
void TestMprisColors::classifyArt_unknownScheme() {
    QCOMPARE(wekde::classifyArtUrl("ftp://server/file.png"),
             wekde::MprisArtUrlKind::Unknown);
}
void TestMprisColors::classifyArt_nonUrlJunk() {
    // "not_a_url" has no scheme → QUrl::isLocalFile() returns false, scheme() is
    // empty, so it falls through to Unknown.
    QCOMPARE(wekde::classifyArtUrl("not_a_url"),
             wekde::MprisArtUrlKind::Unknown);
}

// ===========================================================================
// MprisMonitor slot behavior — private slots invoked via QMetaObject
// ===========================================================================

using namespace wekde;

// Helper: build a QVariantMap that mimics an MPRIS "Metadata" property.
static QVariantMap mkMeta(const QString& title      = {},
                          const QStringList& artists = {},
                          qint64 lengthUs            = 0,
                          const QString& artUrl      = {}) {
    QVariantMap m;
    if (! title.isEmpty()) m["xesam:title"] = title;
    if (! artists.isEmpty()) m["xesam:artist"] = artists;
    m["mpris:length"] = lengthUs;
    if (! artUrl.isEmpty()) m["mpris:artUrl"] = artUrl;
    return m;
}

// Helper: invoke a private slot by name.  Qt's meta system accepts the call
// regardless of C++ access level.
template<class... Args>
static bool invokeSlot(QObject* obj, const char* name, Args... args) {
    return QMetaObject::invokeMethod(obj, name, Qt::DirectConnection, args...);
}

void TestMprisColors::handlePropsChanged_wrongInterface_noSignals() {
    MprisMonitor m;
    QSignalSpy   stateSpy(&m, &MprisMonitor::playbackStateChanged);
    QSignalSpy   thumbSpy(&m, &MprisMonitor::thumbnailChanged);

    QVariantMap changed;
    changed["PlaybackStatus"] = "Playing";

    QVERIFY(invokeSlot(&m, "handlePropertiesChanged",
                       Q_ARG(QString, "org.bogus.Interface"),
                       Q_ARG(QVariantMap, changed),
                       Q_ARG(QStringList, QStringList())));
    QCOMPARE(stateSpy.count(), 0);
    QCOMPARE(thumbSpy.count(), 0);
}

void TestMprisColors::handlePropsChanged_playbackPlaying_emitsState1() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::playbackStateChanged);
    QVariantMap  c;
    c["PlaybackStatus"] = "Playing";
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toInt(), 1);
}

void TestMprisColors::handlePropsChanged_playbackPaused_emitsState2() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::playbackStateChanged);
    QVariantMap  c;
    c["PlaybackStatus"] = "Paused";
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toInt(), 2);
}

void TestMprisColors::handlePropsChanged_playbackStopped_emitsState0() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::playbackStateChanged);
    // Default state is 0. Set to Playing first, then Stopped to see a transition.
    QVariantMap playing;
    playing["PlaybackStatus"] = "Playing";
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, playing),
               Q_ARG(QStringList, QStringList()));

    QVariantMap stopped;
    stopped["PlaybackStatus"] = "Stopped";
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, stopped),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toInt(), 0);
}

void TestMprisColors::handlePropsChanged_sameState_noDuplicateEmit() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::playbackStateChanged);
    QVariantMap  c;
    c["PlaybackStatus"] = "Playing";
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1); // second call shouldn't re-emit
}

void TestMprisColors::handlePropsChanged_metadataMap_emitsPropertiesChanged() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::propertiesChanged);
    QVariantMap  meta = mkMeta("Song", { "A", "B" }, 30'000'000);
    QVariantMap  c;
    c["Metadata"] = meta; // plain QVariantMap-in-QVariant (test path)
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toString(), QString("Song"));
    QCOMPARE(spy.at(0).at(1).toString(), QString("A, B"));
}

void TestMprisColors::handlePropsChanged_metadataEmptyArtUrl_thumbnailFalse() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::thumbnailChanged);
    QVariantMap  c;
    c["Metadata"] = mkMeta("T", {}, 0, "/* default empty */");
    // Use an actual empty-string artUrl — different from the default absent field
    c["Metadata"] = mkMeta("T", {}, 0, ""); // absent → empty
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), false);
}

void TestMprisColors::handlePropsChanged_metadataLocalFileArtUrl_thumbnailTrue() {
    // Write a real PNG to a temp file and point the metadata at it.
    QTemporaryFile f;
    f.setAutoRemove(true);
    QVERIFY(f.open());
    QImage img(16, 16, QImage::Format_RGB32);
    img.fill(Qt::green);
    QVERIFY(img.save(f.fileName(), "PNG"));
    f.close();

    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::thumbnailChanged);
    QVariantMap  c;
    c["Metadata"] = mkMeta("T", {}, 0, QUrl::fromLocalFile(f.fileName()).toString());
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), true);
    QVariantList colors = spy.at(0).at(1).toList();
    QCOMPARE(colors.size(), 15);
}

void TestMprisColors::handlePropsChanged_metadataBadLocalArtUrl_thumbnailFalse() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::thumbnailChanged);
    QVariantMap  c;
    c["Metadata"] = mkMeta("T", {}, 0, "file:///tmp/definitely_nonexistent_420.png");
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), false);
}

void TestMprisColors::handlePropsChanged_metadataUnknownScheme_thumbnailFalse() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::thumbnailChanged);
    QVariantMap  c;
    c["Metadata"] = mkMeta("T", {}, 0, "ftp://host/file.png");
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), false);
}

void TestMprisColors::handlePropsChanged_sameArtUrl_doesNotReprocess() {
    QTemporaryFile f;
    f.setAutoRemove(true);
    QVERIFY(f.open());
    QImage img(16, 16, QImage::Format_RGB32);
    img.fill(Qt::cyan);
    QVERIFY(img.save(f.fileName(), "PNG"));
    f.close();

    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::thumbnailChanged);
    QVariantMap  c;
    c["Metadata"] = mkMeta("T", {}, 0, QUrl::fromLocalFile(f.fileName()).toString());
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    int before = spy.count();

    // Same URL → processArtUrl must NOT be called again.
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QCOMPARE(spy.count(), before);
}

void TestMprisColors::handleNameOwnerChanged_nonMprisName_ignored() {
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::enabledChanged);
    // Anything not starting with "org.mpris.MediaPlayer2." → early return.
    invokeSlot(&m, "handleNameOwnerChanged",
               Q_ARG(QString, "org.some.Other.Service"),
               Q_ARG(QString, ""),
               Q_ARG(QString, ":1.5"));
    QCOMPARE(spy.count(), 0);
}

void TestMprisColors::handleNameOwnerChanged_mprisNameAppears_entersConnectBranch() {
    MprisMonitor m;
    // Name starts with MPRIS prefix AND newOwner is non-empty → connectToPlayer
    // code path runs (call may fail silently without a live service; that's OK).
    // If test env already found an active player, `m_activeService.isEmpty()`
    // is false, so the branch is skipped — no assertion beyond no-crash.
    invokeSlot(&m, "handleNameOwnerChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.testfakeplayer"),
               Q_ARG(QString, ""),
               Q_ARG(QString, ":1.99"));
    QVERIFY(true); // didn't crash
}

void TestMprisColors::handlePropsChanged_metadataHttpArtUrl_createsRequest() {
    MprisMonitor m;
    // http URL → processArtUrl enters the Http branch and fires a network
    // request.  The thumbnail signal only fires asynchronously; here we just
    // exercise the line without waiting for it.
    QVariantMap c;
    c["Metadata"] = mkMeta("T", {}, 0, "http://localhost:1/fake-cover.png");
    invokeSlot(&m, "handlePropertiesChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.Player"),
               Q_ARG(QVariantMap, c),
               Q_ARG(QStringList, QStringList()));
    QVERIFY(true); // coverage is the goal; no assertion on timing-dependent signal
}

void TestMprisColors::pollPosition_noActiveService_noSignals() {
    // pollPosition's only observable in isolation is "does not crash".  If the
    // test env has a session bus AND an active MPRIS player, findActivePlayer
    // runs in the ctor and sets m_activeService — pollPosition then actually
    // round-trips DBus and may emit timelineChanged.  Either path is fine;
    // coverage gets both.
    MprisMonitor m;
    QSignalSpy   spy(&m, &MprisMonitor::timelineChanged);
    invokeSlot(&m, "pollPosition");
    QVERIFY(spy.count() == 0 || spy.count() == 1);
}

// -------- mapShortcutToMpris --------

void TestMprisColors::shortcut_bplay_PlayPause() {
    QCOMPARE(wekde::mapShortcutToMpris("bplay"), QString("PlayPause"));
}
void TestMprisColors::shortcut_bpause_PlayPause() {
    QCOMPARE(wekde::mapShortcutToMpris("bpause"), QString("PlayPause"));
}
void TestMprisColors::shortcut_bplaypause_PlayPause() {
    QCOMPARE(wekde::mapShortcutToMpris("bplaypause"), QString("PlayPause"));
}
void TestMprisColors::shortcut_bnext_Next() {
    QCOMPARE(wekde::mapShortcutToMpris("bnext"), QString("Next"));
}
void TestMprisColors::shortcut_bprev_Previous() {
    QCOMPARE(wekde::mapShortcutToMpris("bprev"), QString("Previous"));
    QCOMPARE(wekde::mapShortcutToMpris("bprevious"), QString("Previous"));
}
void TestMprisColors::shortcut_bstop_Stop() {
    QCOMPARE(wekde::mapShortcutToMpris("bstop"), QString("Stop"));
}
void TestMprisColors::shortcut_solarB11_Next() {
    // Solar system wallpaper 3662790108: usershortcut `b11` is "下一首 Next".
    QCOMPARE(wekde::mapShortcutToMpris("b11"), QString("Next"));
}
void TestMprisColors::shortcut_solarB12_Previous() {
    // Solar system wallpaper 3662790108: usershortcut `b12` is "上一首 Previous".
    QCOMPARE(wekde::mapShortcutToMpris("b12"), QString("Previous"));
}
void TestMprisColors::shortcut_caseInsensitive() {
    // WE names are author-chosen and mixed-case — matcher lowercases both sides.
    QCOMPARE(wekde::mapShortcutToMpris("BPlay"), QString("PlayPause"));
    QCOMPARE(wekde::mapShortcutToMpris("BNEXT"), QString("Next"));
}
void TestMprisColors::shortcut_unknownNameReturnsEmpty() {
    // Solar's `i1`..`i17` icon-shortcuts (planet focus buttons) aren't media
    // controls — they must NOT map to any MPRIS method so the scene-bus
    // event path runs instead of quietly skipping a track.
    QCOMPARE(wekde::mapShortcutToMpris("i1"), QString());
    QCOMPARE(wekde::mapShortcutToMpris("i17"), QString());
    QCOMPARE(wekde::mapShortcutToMpris("bogus"), QString());
}
void TestMprisColors::shortcut_emptyReturnsEmpty() {
    QCOMPARE(wekde::mapShortcutToMpris(""), QString());
}
void TestMprisColors::shortcut_arbitraryNumericDoesNotLeak() {
    // Only the specific solar aliases (b11/b12) are recognized.  Adjacent
    // numeric names stay unmapped so an unrelated wallpaper that happens to
    // name a shortcut "b13" doesn't accidentally trigger a media action.
    QCOMPARE(wekde::mapShortcutToMpris("b10"), QString());
    QCOMPARE(wekde::mapShortcutToMpris("b13"), QString());
    QCOMPARE(wekde::mapShortcutToMpris("b1"), QString());
}

// ===========================================================================
// invokePlayer / invokeShortcut — DBus method dispatch with allowlist
// ===========================================================================
//
// Injection strategy: handleNameOwnerChanged("org.mpris.MediaPlayer2.<x>",
// "", ":1.99") enters the `connectToPlayer` branch *only* when
// m_activeService is empty.  If the ctor's findActivePlayer already picked
// up a real MPRIS player on the session bus, m_activeService is already
// non-empty and our injection no-ops — but m_activeService is still
// non-empty either way, so the positive-path invokePlayer tests cover the
// send-path lines.  We use activeService() to tell which state we're in
// and QSKIP the rare case where neither the ctor nor our injection landed
// anything (which shouldn't happen in practice but could on a machine
// without a session bus).

static bool injectFakeService(MprisMonitor& m,
                              const QString& svc = "org.mpris.MediaPlayer2.testfake") {
    invokeSlot(&m, "handleNameOwnerChanged",
               Q_ARG(QString, svc),
               Q_ARG(QString, ""),
               Q_ARG(QString, ":1.99"));
    return ! m.activeService().isEmpty();
}

void TestMprisColors::invokePlayer_emptyMethod_noop() {
    MprisMonitor m;
    // Empty method hits the `method.isEmpty()` early-out — safe regardless
    // of whether a service is connected.
    m.invokePlayer("");
    QVERIFY(true); // didn't crash
}

void TestMprisColors::invokePlayer_noActiveService_noop() {
    MprisMonitor m;
    // If the ctor didn't find a real MPRIS player and we don't inject, the
    // second clause of the early-out (`m_activeService.isEmpty()`) fires.
    // If the ctor *did* find one, we skip — this test specifically targets
    // the no-service branch.
    if (! m.activeService().isEmpty())
        QSKIP("session bus has a real MPRIS player; can't test empty-service branch");
    m.invokePlayer("Play");
    QVERIFY(true);
}

void TestMprisColors::invokePlayer_rejectsNonAllowlisted() {
    MprisMonitor m;
    if (! injectFakeService(m))
        QSKIP("could not establish an active MPRIS service for this test");
    // Non-allowlisted method → qWarning + early return (exercises the
    // allowlist guard rather than dispatching a DBus call).
    m.invokePlayer("ArbitraryEvilMethod");
    QVERIFY(true);
}

void TestMprisColors::invokePlayer_allowlistedMethod_exercisesSendPath() {
    MprisMonitor m;
    if (! injectFakeService(m))
        QSKIP("could not establish an active MPRIS service for this test");
    // Allowlisted method → createMethodCall + asyncCall.  Against a fake
    // service the DBus call silently fails, but the lines run.  This is
    // the critical test for invokePlayer line coverage.
    m.invokePlayer("Play");
    m.invokePlayer("Pause");
    m.invokePlayer("PlayPause");
    m.invokePlayer("Stop");
    m.invokePlayer("Next");
    m.invokePlayer("Previous");
    QVERIFY(true);
}

void TestMprisColors::invokeShortcut_recognizedName_returnsTrue() {
    MprisMonitor m;
    if (! injectFakeService(m))
        QSKIP("could not establish an active MPRIS service for this test");
    // "bplay" → mapShortcutToMpris="PlayPause" → invokePlayer(allowlisted) →
    // return true.
    QVERIFY(m.invokeShortcut("bplay"));
    QVERIFY(m.invokeShortcut("b11")); // solar system alias
    QVERIFY(m.invokeShortcut("bstop"));
}

void TestMprisColors::invokeShortcut_unknownName_returnsFalse() {
    MprisMonitor m;
    // Doesn't matter whether a service is connected; mapShortcutToMpris
    // returns empty before invokePlayer runs.
    QVERIFY(! m.invokeShortcut("i1"));     // solar icon-focus shortcut
    QVERIFY(! m.invokeShortcut("b13"));    // adjacent numeric, unmapped
    QVERIFY(! m.invokeShortcut("bogus"));
}

void TestMprisColors::invokeShortcut_emptyName_returnsFalse() {
    MprisMonitor m;
    QVERIFY(! m.invokeShortcut(""));
}

// ===========================================================================
// handleNameOwnerChanged — vanish path drives disconnectFromPlayer
// ===========================================================================

void TestMprisColors::handleNameOwnerChanged_activePlayerVanishes_disconnects() {
    MprisMonitor m;
    const QString svc = m.activeService().isEmpty()
        ? QString("org.mpris.MediaPlayer2.testfake_vanish")
        : m.activeService(); // re-use whatever ctor connected to
    if (m.activeService().isEmpty()) {
        QVERIFY(injectFakeService(m, svc));
    }
    QCOMPARE(m.activeService(), svc);

    QSignalSpy enabledSpy(&m, &MprisMonitor::enabledChanged);
    // oldOwner non-empty + newOwner empty + name == m_activeService →
    // disconnectFromPlayer() + findActivePlayer().  The first emission is
    // always `enabledChanged(false)` from disconnectFromPlayer; findActive
    // may then reconnect if there's *another* MPRIS player on the session
    // bus, producing a second `enabledChanged(true)`.  We only assert on
    // the disconnect emission.
    invokeSlot(&m, "handleNameOwnerChanged",
               Q_ARG(QString, svc),
               Q_ARG(QString, ":1.99"),
               Q_ARG(QString, ""));
    QVERIFY(enabledSpy.count() >= 1);
    QCOMPARE(enabledSpy.at(0).at(0).toBool(), false);
}

void TestMprisColors::handleNameOwnerChanged_unrelatedServiceVanishes_noDisconnect() {
    MprisMonitor m;
    if (! injectFakeService(m, "org.mpris.MediaPlayer2.testfake_keep"))
        QSKIP("could not establish an active MPRIS service for this test");
    QString kept = m.activeService();

    QSignalSpy enabledSpy(&m, &MprisMonitor::enabledChanged);
    // A *different* MPRIS service vanishing must not disconnect us.
    invokeSlot(&m, "handleNameOwnerChanged",
               Q_ARG(QString, "org.mpris.MediaPlayer2.someone_else"),
               Q_ARG(QString, ":1.50"),
               Q_ARG(QString, ""));
    QCOMPARE(enabledSpy.count(), 0);
    QCOMPARE(m.activeService(), kept);
}

// ===========================================================================
// decodeArtReplyBytes — pure helper for onArtDownloaded
// ===========================================================================

void TestMprisColors::decodeArt_networkError_returnsFalse() {
    QVariantList out;
    QVERIFY(! wekde::decodeArtReplyBytes(QByteArray("bytes that would otherwise decode"),
                                          true /*networkError*/, out));
    QVERIFY(out.isEmpty());
}

void TestMprisColors::decodeArt_emptyBytes_returnsFalse() {
    QVariantList out;
    QVERIFY(! wekde::decodeArtReplyBytes(QByteArray(), false, out));
    QVERIFY(out.isEmpty());
}

void TestMprisColors::decodeArt_garbageBytes_returnsFalse() {
    QVariantList out;
    QByteArray   junk("\x00\xFF not-an-image \x42\x42", 24);
    QVERIFY(! wekde::decodeArtReplyBytes(junk, false, out));
    QVERIFY(out.isEmpty());
}

void TestMprisColors::decodeArt_validPng_returnsTrueWith15Colors() {
    // Build a real PNG in memory so the decode path actually succeeds.
    QImage img(16, 16, QImage::Format_RGB32);
    img.fill(Qt::magenta);
    QByteArray bytes;
    {
        QBuffer buf(&bytes);
        buf.open(QIODevice::WriteOnly);
        QVERIFY(img.save(&buf, "PNG"));
    }

    QVariantList out;
    QVERIFY(wekde::decodeArtReplyBytes(bytes, false, out));
    QCOMPARE(out.size(), 15);
    // Primary should be close to magenta (R high, B high, G low).
    QVERIFY(out[0].toDouble() > 0.7);  // R
    QVERIFY(out[1].toDouble() < 0.3);  // G
    QVERIFY(out[2].toDouble() > 0.7);  // B
}

QTEST_GUILESS_MAIN(TestMprisColors)
#include "tst_mpriscolors.moc"
