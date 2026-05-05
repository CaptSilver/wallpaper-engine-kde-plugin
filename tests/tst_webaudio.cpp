// Tests for WebAudioBridge — the system-audio FFT relay that feeds web
// wallpapers via QWebChannel.  We bypass the real AudioCapture (which would
// open a PulseAudio/PipeWire .monitor source) by stubbing it in this TU,
// then exercise the bridge through its public test hooks.

#include "WebAudioBridge.hpp"
#include "Audio/AudioAnalyzer.h"
#include "Audio/AudioCapture.h"

#include <QCoreApplication>
#include <QObject>
#include <QSignalSpy>
#include <QTest>
#include <QVariantList>
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

        QVariantList buf = wekde::WebAudioBridge::encodeBuffer(a);
        QCOMPARE(buf.size(), 128);
        // Values should be in [0, ~1] after softSat normalization.  At least
        // one bin near 440Hz must register non-zero magnitude.
        bool sawNonZero = false;
        for (const QVariant& v : buf) {
            double d = v.toDouble();
            QVERIFY(d >= 0.0);
            QVERIFY(d <= 1.5); // soft-sat asymptote, not a hard clamp
            if (d > 0.0001) sawNonZero = true;
        }
        QVERIFY(sawNonZero);
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

        const QVariantList samples = spy.first().first().toList();
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
