// Tests for WebAudioBridge — the system-audio FFT relay that feeds web
// wallpapers via QWebChannel.  We bypass the real AudioCapture (which would
// open a PulseAudio/PipeWire .monitor source) by stubbing it in this TU,
// then exercise the bridge through its public test hooks.

#include "WebAudioBridge.hpp"
#include "Audio/AudioAnalyzer.h"
#include "Audio/AudioBus.h"
#include "Audio/AudioCapture.h"

#include <QCoreApplication>
#include <QList>
#include <QObject>
#include <QSignalSpy>
#include <QTest>
#include <QThread>
#include <cmath>
#include <memory>
#include <vector>

// ── AudioCapture stub ─────────────────────────────────────────────────────
// WebAudioBridge.cpp constructs an AudioCapture during start(); without a
// real implementation the test would link-fail.  We give it an inert one
// so start() simply reports "no monitor source" and falls through.
namespace wallpaper::audio
{

struct AudioCapture::Impl {};

AudioCapture::AudioCapture(): m_impl(std::make_unique<Impl>()) {}
AudioCapture::~AudioCapture() = default;
bool AudioCapture::Init(std::shared_ptr<AudioAnalyzer>) { return false; }
bool AudioCapture::IsActive() const { return false; }
void AudioCapture::Stop() {}

} // namespace wallpaper::audio

namespace
{
// The analyzer requires at least one full FFT_SIZE worth of samples per
// channel (it batches in a ring buffer).  Match the constant used in
// AudioAnalyzer.cpp — 512 samples * 2 channels = 1024 interleaved floats.
constexpr int FFT_SIZE = 512;

QList<qreal> makeSineStereo(int frames, double freqHz, double sampleRate) {
    QList<qreal> out;
    out.reserve(frames * 2);
    for (int i = 0; i < frames; ++i) {
        double t = double(i) / sampleRate;
        double v = std::sin(2.0 * M_PI * freqHz * t) * 0.8;
        out.append(v);
        out.append(v);
    }
    return out;
}
} // namespace

class WebAudioTest : public QObject {
    Q_OBJECT

private slots:
    // ── encodeBuffer (pure helper) ──────────────────────────────────────
    void encodeBuffer_emptyWhenNoData() {
        wallpaper::audio::AudioAnalyzer a;
        QVERIFY(! a.HasData());
        QVERIFY(wekde::WebAudioBridge::encodeBuffer(a).isEmpty());
    }

    void encodeBuffer_returns128FloatsAfterProcess() {
        wallpaper::audio::AudioAnalyzer a;
        auto                            pcm = makeSineStereo(FFT_SIZE * 2, 440.0, 48000.0);
        std::vector<float>              floats;
        floats.reserve(pcm.size());
        for (qreal v : pcm) floats.push_back(float(v));
        a.FeedPcm(floats.data(), uint32_t(floats.size() / 2), 2);
        a.Process();
        QVERIFY(a.HasData());

        QList<double> buf = wekde::WebAudioBridge::encodeBuffer(a);
        QCOMPARE(buf.size(), 128);
        // Values should be in [0, ~1] after softSat normalization.  At least
        // one bin near 440Hz must register non-zero magnitude.
        bool sawNonZero = false;
        for (double d : buf) {
            QVERIFY(d >= 0.0);
            QVERIFY(d <= 1.5); // soft-sat asymptote, not a hard clamp
            if (d > 0.0001) sawNonZero = true;
        }
        QVERIFY(sawNonZero);
    }

    // Pin the signal payload type against accidental reversion to
    // QVariantList. The 30Hz signal must use contiguous-primitive storage;
    // a regression to QVariantList silently re-introduces 128 per-tick
    // heap boxes.
    void encodeBuffer_returnsQListOfDoubles_notQVariantList() {
        wallpaper::audio::AudioAnalyzer a;
        auto                            pcm = makeSineStereo(FFT_SIZE * 2, 440.0, 48000.0);
        std::vector<float>              floats;
        floats.reserve(pcm.size());
        for (qreal v : pcm) floats.push_back(float(v));
        a.FeedPcm(floats.data(), uint32_t(floats.size() / 2), 2);
        a.Process();
        QVERIFY(a.HasData());

        auto buf = wekde::WebAudioBridge::encodeBuffer(a);
        // Compile-time enforcement: encodeBuffer must return QList<double>.
        static_assert(std::is_same_v<decltype(buf), QList<double>>,
                      "encodeBuffer must return QList<double> (not QVariantList)");
        // Runtime cross-check via Qt metatype id.
        QCOMPARE(QMetaType::fromType<decltype(buf)>().id(),
                 QMetaType::fromType<QList<double>>().id());
        QVERIFY(QMetaType::fromType<decltype(buf)>().id() != QMetaType::QVariantList);
    }

    // Pin the receiver-side contract: a slot taking const QList<double>&
    // resolves correctly when audioBuffer fires. If a future refactor
    // re-types the signal (e.g. to QList<float> or QVector<double>),
    // this slot's signature fails to compile.
    void audioBuffer_signalDeliversQListDoubleToReceiver() {
        wekde::WebAudioBridge bridge;
        QList<double>         received;
        QObject::connect(
            &bridge, &wekde::WebAudioBridge::audioBuffer, [&received](const QList<double>& s) {
                received = s;
            });

        QVERIFY(bridge.feedTestPcm(makeSineStereo(FFT_SIZE * 2, 440.0, 48000.0), 2));
        bridge.runOneTick();
        QCOMPARE(received.size(), 128);
        // Each element is a double (compile-time enforced by the lambda's
        // signature; runtime spot-check: in [0, ~1.5] range per the FFT
        // soft-sat contract).
        QVERIFY(received.first() >= 0.0 && received.first() <= 1.5);
    }

    // ── feedTestPcm + runOneTick (signal contract) ───────────────────────
    void runOneTick_emitsAudioBufferOnceAnalyzerHasData() {
        wekde::WebAudioBridge bridge;
        QSignalSpy            spy(&bridge, &wekde::WebAudioBridge::audioBuffer);

        // Empty tick before any PCM: no signal.
        bridge.runOneTick();
        QCOMPARE(spy.count(), 0);

        QVERIFY(bridge.feedTestPcm(makeSineStereo(FFT_SIZE * 2, 440.0, 48000.0), 2));
        bridge.runOneTick();
        QCOMPARE(spy.count(), 1);

        // QSignalSpy delivers each arg as a QVariant; for QList<double>
        // signals unpack via .value<QList<double>>() (Qt6 auto-registers
        // QList<double> for QVariant conversion).
        const QList<double> samples = spy.first().first().value<QList<double>>();
        QCOMPARE(samples.size(), 128);
    }

    void feedTestPcm_lazyCreatesAnalyzer() {
        wekde::WebAudioBridge bridge;
        QVERIFY(! bridge.enabled());
        // Even with enabled=false, feedTestPcm should set up an analyzer
        // for deterministic testing — otherwise tests would have to flip
        // the capture lifecycle on (and we don't link AudioCapture for real).
        QVERIFY(bridge.feedTestPcm(makeSineStereo(FFT_SIZE * 2, 1000.0, 48000.0), 2));
    }

    // ── enabled lifecycle ────────────────────────────────────────────────
    void setEnabled_emitsChangeSignalAndIsIdempotent() {
        wekde::WebAudioBridge bridge;
        QSignalSpy            spy(&bridge, &wekde::WebAudioBridge::enabledChanged);

        bridge.setEnabled(true);
        // Capture init returns false in the stub, but `enabled` still flips
        // (tracking what the user requested, not what hardware delivered).
        QVERIFY(bridge.enabled());
        QCOMPARE(spy.count(), 1);

        // Idempotent — re-setting the same value shouldn't re-emit.
        bridge.setEnabled(true);
        QCOMPARE(spy.count(), 1);

        bridge.setEnabled(false);
        QVERIFY(! bridge.enabled());
        QCOMPARE(spy.count(), 2);
    }

    // ── AudioBus spectrum lease ─────────────────────────────────────────
    // The bus's own 60 Hz thread is the only caller of AudioAnalyzer::Process,
    // and it only runs the FFT while somebody declares that they read the
    // spectrum.  An enabled bridge is exactly such a consumer, so without a
    // lease a web wallpaper would sample an all-zero spectrum forever.
    void enabledBridge_leasesTheBusSpectrum() {
        qputenv("WEK_TEST_AUDIO_NULL_CAPTURE", "1");
        wallpaper::audio::AudioBus::TEST_resetForNextCase();

        wekde::WebAudioBridge bridge;
        bridge.setEnabled(true);

        // Same singleton analyzer the bridge holds; feed it two full windows.
        auto analyzer = wallpaper::audio::AudioBus::Acquire(false);
        QVERIFY(analyzer);
        std::vector<float> pcm(4096, 0.25f);
        analyzer->FeedPcm(pcm.data(), 2048, 2);

        quint64 processed = 0;
        for (int i = 0; i < 200 && processed == 0; ++i) {
            QThread::msleep(10);
            processed = analyzer->WindowsProcessedForTest();
        }
        QVERIFY(processed > 0);

        // Disabling withdraws the lease — fresh PCM must sit unconsumed.
        bridge.setEnabled(false);
        QThread::msleep(50);
        const quint64 afterDisable = analyzer->WindowsProcessedForTest();
        analyzer->FeedPcm(pcm.data(), 2048, 2);
        QThread::msleep(160);
        QCOMPARE(analyzer->WindowsProcessedForTest(), afterDisable);

        analyzer.reset();
        wallpaper::audio::AudioBus::TEST_resetForNextCase();
    }

    void feedTestPcm_refusesToTouchTheSharedBusAnalyzer() {
        // While enabled, m_analyzer IS the bus singleton, and the bus thread
        // owns its Process().  Running an FFT here would make the test hook a
        // second, unsynchronised consumer.
        qputenv("WEK_TEST_AUDIO_NULL_CAPTURE", "1");
        wallpaper::audio::AudioBus::TEST_resetForNextCase();

        wekde::WebAudioBridge bridge;
        bridge.setEnabled(true);
        QVERIFY(! bridge.feedTestPcm(makeSineStereo(FFT_SIZE * 2, 440.0, 48000.0), 2));

        bridge.setEnabled(false);
        wallpaper::audio::AudioBus::TEST_resetForNextCase();
    }

    void setIntervalMs_validatesAndEmits() {
        wekde::WebAudioBridge bridge;
        QSignalSpy            spy(&bridge, &wekde::WebAudioBridge::intervalMsChanged);

        const int initial = bridge.intervalMs();
        QVERIFY(initial > 0);

        // Reject zero/negative — preserves the timer's invariant.
        bridge.setIntervalMs(0);
        QCOMPARE(bridge.intervalMs(), initial);
        QCOMPARE(spy.count(), 0);
        bridge.setIntervalMs(-5);
        QCOMPARE(bridge.intervalMs(), initial);
        QCOMPARE(spy.count(), 0);

        // No-op when unchanged.
        bridge.setIntervalMs(initial);
        QCOMPARE(spy.count(), 0);

        bridge.setIntervalMs(50);
        QCOMPARE(bridge.intervalMs(), 50);
        QCOMPARE(spy.count(), 1);
    }
};

QTEST_MAIN(WebAudioTest)
#include "tst_webaudio.moc"
