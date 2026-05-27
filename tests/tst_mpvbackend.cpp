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
#include <QTemporaryDir>
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

    // status NOTIFY wiring: pure derivation, change-diff/emit, event-queue drain.
    void deriveStatus_idleActive_isStopped();
    void deriveStatus_active_paused_isPaused();
    void deriveStatus_active_unpaused_isPlaying();
    void refreshStatus_changed_emitsOnce();
    void refreshStatus_unchanged_doesNotEmit();
    void onMpvEvents_idlePlayer_doesNotEmit();

    // setSource failure paths emit sourceLoadFailed instead of falling
    // through silently (which today costs the user 15s of black before the
    // QML watchdog fires a generic message).  Two failure shapes:
    //   - sync: mpv's command parser rejects the loadfile (rare in practice
    //     for QUrl-derived paths; covered by command() returning false).
    //   - async: mpv accepts loadfile, then fires MPV_EVENT_END_FILE with
    //     reason=ERROR when open(2)/demux fails.
    void setSource_invalidLocalPath_emitsSourceLoadFailed_async();
    void setSource_validFixture_doesNotEmitSourceLoadFailed();
    void sourceLoadFailed_carriesNonEmptyReason();
    void sourceChanged_notEmittedOnAsyncEndFileError();

    // Regression: constructor used to set `loop`, `vo`, `hwdec`, `config`
    // *after* mpv_initialize(), where mpv silently drops them.
    void constructor_setsLoopOptionBeforeInit();

    // Wallpaper-tuned mpv init options must be set before mpv_initialize so
    // the option surface accepts them; verify the values via getProperty.
    void initOptions_disableAudioAndCache();
    void initOptions_msgLevelRespectsEnv();

    // m_first_frame is atomic + flipped via exchange(); checkAndEmitFirstFrame
    // must emit firstFrame() at most once per setSource transition (the GUI
    // thread writes m_first_frame=false, the render thread flips it back true
    // and emits exactly once — see MpvBackend.cpp:checkAndEmitFirstFrame).
    void firstFrame_freshObject_doesNotEmit();
    void firstFrame_afterSourceFlip_emitsExactlyOnce();

    // wakeup() runs on an arbitrary mpv player thread; rapid construct/destroy
    // cycles must not deref a freed MpvObject (the .so is dlopen'd into
    // plasmashell, where a dangling postEvent would crash the desktop).
    void destroy_after_brief_lifetime_is_safe();

    // status() reads the cached m_lastStatus (maintained by event-driven
    // refreshStatus on observed-property changes); it must NOT issue any
    // sync mpv_get_property calls. liveStatus() retains the old sync-read
    // body for the single bootstrap site at ctor time.
    void status_reflectsRefreshStatusCache_noSyncReads();
    void status_returnsCachedValueAcrossManyCalls();
    void status_playPauseSequenceFinalStateCorrect();

    // NOTIFY emission for the imperative-set Q_PROPERTYs: each setter must
    // fire its corresponding *Changed() signal so QML bindings re-evaluate
    // when the property is written via `mpv.mute = ...` / `mpv.volume = ...`
    // / `mpv.logfile = ...`. Matches the SceneBackend::setVolume pattern.
    void muteChanged_emitsOnSetMute();
    void volumeChanged_emitsOnSetVolume();
    void logfileChanged_emitsOnSetLogfile();
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
    auto          obj = makeObject();
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString logPath = dir.filePath(QStringLiteral("wekde-mpv-test.log"));
    obj->setLogfile(logPath);
    QCOMPARE(obj->logfile(), logPath);
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
    QTemporaryDir scratch;
    QVERIFY(scratch.isValid());
    const QUrl url = QUrl::fromLocalFile(scratch.filePath(QStringLiteral("does-not-exist.mp4")));
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
// before init, `loop-file` should read back as "inf" rather than its libmpv
// default (per-file loop form replaces the deprecated playlist-loop alias).
void TestMpvBackend::constructor_setsLoopOptionBeforeInit() {
    auto obj = makeObject();
    QCOMPARE(obj->getProperty("loop-file").toString(), QStringLiteral("inf"));
}

// Wallpapers re-read from disk on each loop cycle (cache=no) and have no
// audio path on the QML side (audio=no).  Decode thread cap (vd-lavc-threads=2)
// and video-sync=display-resample tune the loop wrap for shipping defaults.
// libmpv normalises boolean options post-init: "no" reads back as "false";
// "auto"/text/numeric options round-trip verbatim.
void TestMpvBackend::initOptions_disableAudioAndCache() {
    auto obj = makeObject();
    QVERIFY(obj->initialized());
    QCOMPARE(obj->getProperty("cache").toString(), QStringLiteral("false"));
    QCOMPARE(obj->getProperty("audio").toString(), QStringLiteral("false"));
    QCOMPARE(obj->getProperty("vd-lavc-threads").toString(), QStringLiteral("2"));
    QCOMPARE(obj->getProperty("video-sync").toString(), QStringLiteral("display-resample"));
    QCOMPARE(obj->getProperty("loop-file").toString(), QStringLiteral("inf"));
}

// Default is warn so journald stays clean; WEK_MPV_VERBOSE=1 restores info.
// Note: `msg-level` reads back empty post-init (libmpv quirk — the value is
// applied but not exposed via the property surface), so the assertion is
// limited to "object initialises cleanly under both env states".  The env
// gate is exercised at construction time; the value is not observable
// through libmpv's property API.
void TestMpvBackend::initOptions_msgLevelRespectsEnv() {
    // Default: WEK_MPV_VERBOSE unset → warn.
    qunsetenv("WEK_MPV_VERBOSE");
    auto obj1 = makeObject();
    QVERIFY(obj1->initialized());

    // Set: WEK_MPV_VERBOSE=1 → info.
    qputenv("WEK_MPV_VERBOSE", "1");
    auto obj2 = makeObject();
    QVERIFY(obj2->initialized());

    qunsetenv("WEK_MPV_VERBOSE");
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
    // No leading path => Qt6 uses QStandardPaths::TempLocation automatically.
    QTemporaryFile file(QStringLiteral("wekde-mpv-firstframeXXXXXX.mp4"));
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

// status() is a pure mapping of mpv's (idle-active, pause) flags: idle wins
// (Stopped) regardless of pause; otherwise pause picks Paused vs Playing.
void TestMpvBackend::deriveStatus_idleActive_isStopped() {
    QCOMPARE(MpvObject::deriveStatus(true, false), MpvObject::Stopped);
    QCOMPARE(MpvObject::deriveStatus(true, true), MpvObject::Stopped);
}

void TestMpvBackend::deriveStatus_active_paused_isPaused() {
    QCOMPARE(MpvObject::deriveStatus(false, true), MpvObject::Paused);
}

void TestMpvBackend::deriveStatus_active_unpaused_isPlaying() {
    QCOMPARE(MpvObject::deriveStatus(false, false), MpvObject::Playing);
}

// A status transition emits statusChanged exactly once per crossing and reports
// that it changed — the emit site that was previously missing entirely.
void TestMpvBackend::refreshStatus_changed_emitsOnce() {
    auto       obj = makeObject(); // status anchor starts Stopped
    QSignalSpy spy(obj.get(), &MpvObject::statusChanged);
    QVERIFY(obj->refreshStatus(false, false)); // Stopped -> Playing
    QCOMPARE(spy.count(), 1);
    QVERIFY(obj->refreshStatus(false, true)); // Playing -> Paused
    QCOMPARE(spy.count(), 2);
}

// No spurious emit when the derived status is unchanged (the diff guard that
// keeps QML bindings from churning on every observed-property event).
void TestMpvBackend::refreshStatus_unchanged_doesNotEmit() {
    auto       obj = makeObject(); // anchor Stopped
    QSignalSpy spy(obj.get(), &MpvObject::statusChanged);
    QVERIFY(! obj->refreshStatus(true, false)); // Stopped -> Stopped
    QVERIFY(! obj->refreshStatus(true, true));  // still Stopped
    QCOMPARE(spy.count(), 0);
}

// Draining mpv's event queue (including the initial property-change events that
// mpv_observe_property delivers on registration) must not emit statusChanged
// while the player is idle.
void TestMpvBackend::onMpvEvents_idlePlayer_doesNotEmit() {
    auto       obj = makeObject();
    QSignalSpy spy(obj.get(), &MpvObject::statusChanged);
    obj->onMpvEvents(); // idle player => Stopped => no change
    QCOMPARE(spy.count(), 0);
    QCOMPARE(obj->status(), MpvObject::Stopped);
}

// Stress the construct/observe-properties/destroy cycle: each pass starts an
// mpv player thread, registers two observers (pause, idle-active), wires the
// wakeup callback, then immediately tears down. Without the MpvHandle.owner
// indirection + mutex sync in ~MpvObject, a wakeup already on the player
// thread's call stack would deref a freed QObject when the destructor returns.
void TestMpvBackend::destroy_after_brief_lifetime_is_safe() {
    QElapsedTimer t;
    t.start();
    for (int i = 0; i < 32; ++i) {
        auto obj = makeObject();
        if (! obj->initialized()) return; // libmpv unavailable in env
        // Pump the GUI loop briefly so any wakeup that fired has a chance
        // to land before destruction.
        QTest::qWait(5);
    }
    QVERIFY(t.elapsed() < 10000); // 32 × <300 ms each at the loose end
}

// UI4.3: status() must return the cached m_lastStatus that refreshStatus
// maintains from observed mpv property events — not issue sync mpv_get_property
// reads on every call. Drive a transition through refreshStatus, then assert
// status() reflects the cached value (mpv has not seen any setProperty, so a
// sync read would still report Stopped; cache-read reports the new value).
void TestMpvBackend::status_reflectsRefreshStatusCache_noSyncReads() {
    auto obj = makeObject();
    QCOMPARE(obj->status(), MpvObject::Stopped);
    // Force the cache to Playing via refreshStatus (no mpv state actually
    // changed — pure cache poke). A sync-read implementation would still
    // see idle=true,pause=false from mpv → Stopped; a cache-read sees Playing.
    QVERIFY(obj->refreshStatus(false, false));
    QCOMPARE(obj->status(), MpvObject::Playing);
    QVERIFY(obj->refreshStatus(false, true));
    QCOMPARE(obj->status(), MpvObject::Paused);
}

// status() must be idempotent across many calls — the cache, not a sync
// read, drives the value. Without UI4.3, repeated mpv getProperty pairs
// would compound observed-property event-loop pressure for QML bindings
// that read `status` reactively.
void TestMpvBackend::status_returnsCachedValueAcrossManyCalls() {
    auto obj = makeObject();
    QVERIFY(obj->refreshStatus(false, true)); // Stopped → Paused
    const auto cached = obj->status();
    QCOMPARE(cached, MpvObject::Paused);
    for (int i = 0; i < 100; ++i) QCOMPARE(obj->status(), cached);
}

// play()/pause()/stop() gate on status(); under the cache, a back-to-back
// programmatic sequence must converge to the right final state once events
// have been drained.
void TestMpvBackend::status_playPauseSequenceFinalStateCorrect() {
    auto obj = makeObject();
    // Drive cache: Stopped → Playing → Paused → Playing
    QVERIFY(obj->refreshStatus(false, false));
    QCOMPARE(obj->status(), MpvObject::Playing);
    QVERIFY(obj->refreshStatus(false, true));
    QCOMPARE(obj->status(), MpvObject::Paused);
    QVERIFY(obj->refreshStatus(false, false));
    QCOMPARE(obj->status(), MpvObject::Playing);
}

// Async path: mpv accepts loadfile syntactically (so the sync command()
// returns true and sourceChanged DOES fire), then fires MPV_EVENT_END_FILE
// with reason=ERROR when the file open or demux fails.  onMpvEvents() must
// observe that and emit sourceLoadFailed with a non-empty mpv_error_string.
void TestMpvBackend::setSource_invalidLocalPath_emitsSourceLoadFailed_async() {
    auto obj = makeObject();
    obj->initCallback();

    QSignalSpy spy(obj.get(), &MpvObject::sourceLoadFailed);
    const QUrl missing = QUrl::fromLocalFile(QStringLiteral("/var/empty/wekde-does-not-exist.mp4"));
    obj->setSource(missing);
    // mpv accepts the load syntactically; m_source is set.  The END_FILE
    // event fires once mpv tries to open the file (async on the player
    // thread, marshalled through wakeup() onto the GUI thread).
    QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
    QVERIFY(! spy.at(0).at(0).toString().isEmpty());
}

// Happy-path regression: a successful loadfile path must NOT emit
// sourceLoadFailed.  Uses the same tiny stub-mp4 trick as
// firstFrame_afterSourceFlip_emitsExactlyOnce — mpv's loadfile is
// fire-and-forget so the bytes don't have to be a real frame; we only
// assert "no spurious failure during a brief settle".
void TestMpvBackend::setSource_validFixture_doesNotEmitSourceLoadFailed() {
    auto obj = makeObject();
    obj->initCallback();

    QTemporaryFile file(QStringLiteral("wekde-mpv-okXXXXXX.mp4"));
    QVERIFY(file.open());
    file.write(QByteArrayLiteral("\x00\x00\x00\x18"
                                 "ftypmp42"));
    file.flush();

    QSignalSpy spy(obj.get(), &MpvObject::sourceLoadFailed);
    obj->setSource(QUrl::fromLocalFile(file.fileName()));
    QVERIFY2(! obj->source().isEmpty(), "loadfile path not exercised; file may be unwritable");
    // The contract this test asserts is "no SYNC-path emit on a loadfile
    // mpv accepts" — i.e. the new else branch in setSource() must not
    // fire when command() returned true.  The async demuxer may legitimately
    // END_FILE on this stub mp4 a few ms later (it's not a real frame); we
    // explicitly do NOT spin the event loop, so any spy hit here would
    // have to come from a direct sync emit out of setSource.
    QCOMPARE(spy.count(), 0);
}

// Documents the signal contract: the reason string is always non-empty
// (either mpv_error_string output or the literal sync-reject diagnostic).
// Used by the QML Connections block to populate the InfoShow message.
void TestMpvBackend::sourceLoadFailed_carriesNonEmptyReason() {
    auto obj = makeObject();
    obj->initCallback();
    QSignalSpy spy(obj.get(), &MpvObject::sourceLoadFailed);
    obj->setSource(QUrl::fromLocalFile(QStringLiteral("/var/empty/missing.mp4")));
    QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
    const QString reason = spy.at(0).at(0).toString();
    QVERIFY(! reason.isEmpty());
    QVERIFY(reason.size() > 3); // catches accidentally emitting "" or "ok"
}

// Property-contract regression: the existing rule "sourceChanged fires
// iff loadfile was accepted" must not regress.  On the async ERROR path
// mpv DID accept the command (m_source updated, sourceChanged fired
// once), then later reported END_FILE with reason=ERROR — those events
// are not coupled.  Assert sourceChanged fires once and exactly once.
void TestMpvBackend::sourceChanged_notEmittedOnAsyncEndFileError() {
    auto obj = makeObject();
    obj->initCallback();
    QSignalSpy changed(obj.get(), &MpvObject::sourceChanged);
    QSignalSpy failed(obj.get(), &MpvObject::sourceLoadFailed);
    obj->setSource(QUrl::fromLocalFile(QStringLiteral("/var/empty/missing.mp4")));
    QTRY_VERIFY_WITH_TIMEOUT(failed.count() >= 1, 5000);
    // sourceChanged fired exactly once (at sync-accept time); the async
    // ERROR does not retroactively un-emit it.
    QCOMPARE(changed.count(), 1);
}

// Q_PROPERTY mute is declared NOTIFY muteChanged; setMute(true/false) must
// emit it so QML bindings (e.g., a volume-indicator slider) re-evaluate
// when the wallpaper toggles audio. Option B (unconditional emit) matches
// SceneBackend::setVolume's pattern; QML's binding graph dedupes by value.
void TestMpvBackend::muteChanged_emitsOnSetMute() {
    auto       obj = makeObject();
    QSignalSpy spy(obj.get(), &mpv::MpvObject::muteChanged);
    obj->setMute(true);
    QCOMPARE(spy.count(), 1);
    obj->setMute(false);
    QCOMPARE(spy.count(), 2);
}

void TestMpvBackend::volumeChanged_emitsOnSetVolume() {
    auto       obj = makeObject();
    QSignalSpy spy(obj.get(), &mpv::MpvObject::volumeChanged);
    obj->setVolume(50);
    QCOMPARE(spy.count(), 1);
    obj->setVolume(80);
    QCOMPARE(spy.count(), 2);
}

void TestMpvBackend::logfileChanged_emitsOnSetLogfile() {
    auto          obj = makeObject();
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QSignalSpy spy(obj.get(), &mpv::MpvObject::logfileChanged);
    obj->setLogfile(dir.filePath(QStringLiteral("wekde-mpv-test.log")));
    QCOMPARE(spy.count(), 1);
    obj->setLogfile(dir.filePath(QStringLiteral("wekde-mpv-other.log")));
    QCOMPARE(spy.count(), 2);
}

QTEST_MAIN(TestMpvBackend)
#include "tst_mpvbackend.moc"
