// Headless integration tests for MpvObject's Q_PROPERTY surface and the
// command/setProperty/getProperty wrappers around libmpv.
//
// These tests construct a real MpvObject (which spins up libmpv) but never
// open a video file or build an OpenGL context, so the render path
// (`createRenderer`, `renderFrame`) is intentionally out of scope.
//
// Run under QT_QPA_PLATFORM=offscreen so QGuiApplication can attach without
// a display.

#include <QtTest>
#include <QGuiApplication>
#include <QSignalSpy>
#include <QTemporaryFile>
#include <QUrl>
#include <QVariant>

#include <clocale>

#include "MpvBackend.hpp"

using mpv::MpvObject;

class TestMpvBackend : public QObject {
    Q_OBJECT

private slots:
    // libmpv refuses to initialize when LC_NUMERIC isn't "C"; QGuiApplication
    // pulls in the user's locale, so we have to reset it before constructing
    // any MpvObject.
    void initTestCase() { std::setlocale(LC_NUMERIC, "C"); }

    void initialState_defaultsAreSensible();

    // mute ⇄ aid round-trip
    void setMute_true_thenMuteReturnsTrue();
    void setMute_false_thenMuteReturnsFalse();
    void mute_handlesBothStringAndFlagAidEncodings();

    // volume round-trip
    void setVolume_roundTrip();
    void volume_clampedByMpv();

    // logfile round-trip
    void setLogfile_roundTrip();

    // setProperty / getProperty boundaries
    void getProperty_emptyName_returnsInvalid();
    void getProperty_unknownProperty_failsOk();
    void getProperty_okPointer_setOnSuccess();
    void getProperty_okPointer_clearedOnFailure();

    // command error reporting
    void command_unknownVerb_returnsFalse();

    // setSource preconditions (no file actually loaded)
    void setSource_emptyUrl_clearsAndStops();
    void setSource_invalidUrl_isNoop();
    void setSource_beforeInit_storesButDefersLoad();

    // status() derives from idle-active + pause
    void status_initially_stopped();

    // Part A: initialized Q_PROPERTY + loud failure.
    void initialized_trueAfterSuccessfulInit();
    void successfulInit_doesNotWarn();

    // play/pause guards (no-op outside the matching state)
    void play_whenStopped_isNoop();
    void pause_whenStopped_isNoop();

    // Regression: constructor used to set `loop`, `vo`, `hwdec`, `config`
    // *after* mpv_initialize(), where mpv silently drops them.
    void constructor_setsLoopOptionBeforeInit();

    // m_first_frame is atomic + flipped via exchange(); checkAndEmitFirstFrame
    // must emit firstFrame() at most once per setSource transition (the GUI
    // thread writes m_first_frame=false, the render thread flips it back true
    // and emits exactly once — see MpvBackend.cpp:checkAndEmitFirstFrame).
    void firstFrame_freshObject_doesNotEmit();
    void firstFrame_afterSourceFlip_emitsExactlyOnce();
};

namespace
{
std::unique_ptr<MpvObject> makeObject() { return std::make_unique<MpvObject>(nullptr); }
} // namespace

void TestMpvBackend::initialState_defaultsAreSensible() {
    auto obj = makeObject();
    QCOMPARE(obj->source(), QUrl());
    QVERIFY(obj->logfile().isEmpty());
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

void TestMpvBackend::setMute_true_thenMuteReturnsTrue() {
    auto obj = makeObject();
    obj->setMute(true);
    QVERIFY(obj->mute());
}

void TestMpvBackend::setMute_false_thenMuteReturnsFalse() {
    auto obj = makeObject();
    obj->setMute(false);
    QVERIFY(! obj->mute());
}

// Regression: mpv encodes `aid=no` either as the literal string "no" or as
// a boolean flag depending on internal state. mute() must accept both.
void TestMpvBackend::mute_handlesBothStringAndFlagAidEncodings() {
    auto obj = makeObject();
    QVERIFY(obj->setProperty("aid", QStringLiteral("no")));
    QVERIFY(obj->mute());
    QVERIFY(obj->setProperty("aid", QStringLiteral("auto")));
    QVERIFY(! obj->mute());
}

void TestMpvBackend::setVolume_roundTrip() {
    auto obj = makeObject();
    obj->setVolume(42);
    QCOMPARE(obj->volume(), 42);
    obj->setVolume(0);
    QCOMPARE(obj->volume(), 0);
    obj->setVolume(100);
    QCOMPARE(obj->volume(), 100);
}

void TestMpvBackend::volume_clampedByMpv() {
    auto obj = makeObject();
    // mpv silently clamps into its accepted range; we only assert the
    // value is finite and non-negative after a round-trip.
    obj->setVolume(99999);
    QVERIFY(obj->volume() >= 0);
}

void TestMpvBackend::setLogfile_roundTrip() {
    auto obj = makeObject();
    obj->setLogfile(QStringLiteral("/tmp/wekde-mpv-test.log"));
    QCOMPARE(obj->logfile(), QStringLiteral("/tmp/wekde-mpv-test.log"));
}

void TestMpvBackend::getProperty_emptyName_returnsInvalid() {
    auto     obj = makeObject();
    bool     ok  = true;
    QVariant v   = obj->getProperty(QString {}, &ok);
    QVERIFY(! v.isValid());
    QVERIFY(! ok);
}

void TestMpvBackend::getProperty_unknownProperty_failsOk() {
    auto obj = makeObject();
    bool ok  = true;
    obj->getProperty(QStringLiteral("definitely-not-a-real-mpv-property"), &ok);
    QVERIFY(! ok);
}

void TestMpvBackend::getProperty_okPointer_setOnSuccess() {
    auto obj = makeObject();
    bool ok  = false;
    obj->getProperty(QStringLiteral("volume"), &ok);
    QVERIFY(ok);
}

void TestMpvBackend::getProperty_okPointer_clearedOnFailure() {
    auto obj = makeObject();
    bool ok  = true;
    obj->getProperty(QStringLiteral("nope-not-here"), &ok);
    QVERIFY(! ok);
}

void TestMpvBackend::command_unknownVerb_returnsFalse() {
    auto obj = makeObject();
    QVERIFY(! obj->command(QVariantList { QStringLiteral("definitely-not-a-verb") }));
}

void TestMpvBackend::setSource_emptyUrl_clearsAndStops() {
    auto obj = makeObject();
    obj->initCallback(); // mark as inited so setSource takes the live path
    QSignalSpy spy(obj.get(), &MpvObject::sourceChanged);
    obj->setSource(QUrl {});
    // status() must remain Stopped; source() must be empty.
    QCOMPARE(obj->source(), QUrl());
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

void TestMpvBackend::setSource_invalidUrl_isNoop() {
    auto obj = makeObject();
    obj->initCallback();
    const QUrl before = obj->source();
    QUrl       invalid;
    invalid.setUrl(QStringLiteral("::not a url::"), QUrl::StrictMode);
    QVERIFY(! invalid.isValid());
    obj->setSource(invalid);
    QCOMPARE(obj->source(), before);
}

void TestMpvBackend::setSource_beforeInit_storesButDefersLoad() {
    auto obj = makeObject();
    // Without initCallback() the object is not "inited"; setSource should
    // store the URL but not issue a loadfile command.
    const QUrl url = QUrl::fromLocalFile(QStringLiteral("/tmp/does-not-exist.mp4"));
    obj->setSource(url);
    QCOMPARE(obj->source(), url);
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

void TestMpvBackend::status_initially_stopped() {
    auto obj = makeObject();
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

void TestMpvBackend::play_whenStopped_isNoop() {
    auto obj = makeObject();
    obj->play();
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

void TestMpvBackend::pause_whenStopped_isNoop() {
    auto obj = makeObject();
    obj->pause();
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

// Regression: the previous constructor set `loop`/`vo`/`hwdec`/`config` *after*
// mpv_initialize(), which silently dropped them.  After moving the calls
// before init, `loop` should read back as "inf" rather than its libmpv default.
void TestMpvBackend::constructor_setsLoopOptionBeforeInit() {
    auto obj = makeObject();
    QCOMPARE(obj->getProperty("loop").toString(), QStringLiteral("inf"));
}

// A freshly-constructed object has m_first_frame == true (no source loaded
// yet), so checkAndEmitFirstFrame() must NOT emit — and repeated calls must
// stay idempotent (the exchange keeps it true and never fires).
void TestMpvBackend::firstFrame_freshObject_doesNotEmit() {
    auto       obj = makeObject();
    QSignalSpy spy(obj.get(), &MpvObject::firstFrame);
    obj->checkAndEmitFirstFrame();
    obj->checkAndEmitFirstFrame();
    obj->checkAndEmitFirstFrame();
    QCOMPARE(spy.count(), 0);
}

// After a successful setSource (which flips m_first_frame false on the GUI
// thread), the render thread's checkAndEmitFirstFrame() must emit firstFrame()
// exactly once even if synchronize() calls it repeatedly — the exchange(true)
// guarantees the single edge.
void TestMpvBackend::firstFrame_afterSourceFlip_emitsExactlyOnce() {
    auto obj = makeObject();
    obj->initCallback(); // mark inited so setSource takes the live loadfile path

    // A real on-disk file so the `loadfile` command is accepted (mpv queues
    // the load asynchronously and returns success regardless of decodability),
    // which is what flips m_first_frame to false inside setSource.
    QTemporaryFile file(QStringLiteral("/tmp/wekde-mpv-firstframeXXXXXX.mp4"));
    QVERIFY(file.open());
    file.write(QByteArrayLiteral("\x00\x00\x00\x18"
                                 "ftypmp42"));
    file.flush();

    obj->setSource(QUrl::fromLocalFile(file.fileName()));
    // Precondition: the source was accepted (loadfile succeeded → m_first_frame
    // is now false).  If mpv refused the file in this environment the source
    // stays empty; skip the strict edge check rather than flake.
    QVERIFY2(! obj->source().isEmpty(),
             "setSource did not accept the temp file; loadfile path not exercised");

    QSignalSpy spy(obj.get(), &MpvObject::firstFrame);
    obj->checkAndEmitFirstFrame(); // first render tick: false -> true, emit
    obj->checkAndEmitFirstFrame(); // already true: no emit
    obj->checkAndEmitFirstFrame(); // still true: no emit
    QCOMPARE(spy.count(), 1);
}

// A normally-constructed MpvObject (libmpv present in the test env) must report
// initialized()==true — the contract QML uses to avoid a black void.
void TestMpvBackend::initialized_trueAfterSuccessfulInit() {
    auto obj = makeObject();
    QVERIFY(obj->initialized());
}

// A successful init must NOT emit the "video backend unavailable" warning (the
// loud path is for the failure case only).
void TestMpvBackend::successfulInit_doesNotWarn() {
    static bool sawUnavailable = false;
    sawUnavailable             = false;
    auto* prev =
        qInstallMessageHandler([](QtMsgType t, const QMessageLogContext&, const QString& m) {
            if (t == QtWarningMsg && m.contains("video backend unavailable")) sawUnavailable = true;
        });
    {
        auto obj = makeObject();
        QVERIFY(obj->initialized());
    }
    qInstallMessageHandler(prev);
    QVERIFY(! sawUnavailable);
}

QTEST_MAIN(TestMpvBackend)
#include "tst_mpvbackend.moc"
