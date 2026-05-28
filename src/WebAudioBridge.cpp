#include "WebAudioBridge.hpp"

#include "Audio/AudioAnalyzer.h"
#include "Audio/AudioBus.h"

#include <QDebug>
#include <vector>

namespace wekde
{

WebAudioBridge::WebAudioBridge(QObject* parent): QObject(parent) {
    m_timer.setInterval(m_intervalMs);
    QObject::connect(&m_timer, &QTimer::timeout, this, &WebAudioBridge::onTimerTick);
}

WebAudioBridge::~WebAudioBridge() { stop(); }

void WebAudioBridge::setEnabled(bool e) {
    if (e == m_enabled) return;
    m_enabled = e;
    if (e)
        start();
    else
        stop();
    emit enabledChanged();
}

void WebAudioBridge::setIntervalMs(int ms) {
    if (ms <= 0 || ms == m_intervalMs) return;
    m_intervalMs = ms;
    m_timer.setInterval(ms);
    emit intervalMsChanged();
}

void WebAudioBridge::start() {
    // Acquire the shared analyzer from the process-singleton AudioBus.
    // Any scene wallpaper that already opened system capture will share
    // the same PulseAudio monitor stream + FFT pipeline; otherwise the
    // bus opens one on our behalf.  Acquire returns a valid analyzer
    // even when capture-init fails (no .monitor source / PulseAudio
    // missing) — the timer will still run but the spectrum stays empty,
    // matching the pre-bus qWarning fall-through path.
    m_analyzer = wallpaper::audio::AudioBus::Acquire(/*wantSystemCapture=*/true);
    if (! m_analyzer) {
        qWarning() << "WebAudioBridge: AudioBus::Acquire returned null; "
                      "audio-reactive web wallpapers will receive no spectrum data";
        m_timer.stop();
        return;
    }
    if (! wallpaper::audio::AudioBus::HasSystemCapture()) {
        qWarning() << "WebAudioBridge: system audio capture unavailable; "
                      "audio-reactive web wallpapers will receive no spectrum data";
        m_timer.stop();
        return;
    }
    m_timer.start();
}

void WebAudioBridge::stop() {
    m_timer.stop();
    // Dropping the shared_ptr decrements the bus's subscriber count; if
    // we were the last system-capture wanter the bus releases the
    // PulseAudio monitor stream, if we were the last subscriber of any
    // kind it tears the whole bus down.
    m_analyzer.reset();
}

void WebAudioBridge::onTimerTick() {
    if (! m_analyzer) return;
    // The bus owns Process() — the 60Hz internal thread already runs it
    // once per ~16ms.  We just sample the latest spectrum at our own
    // emit cadence (30Hz by default, set via setIntervalMs).
    QList<double> buf = encodeBuffer(*m_analyzer);
    if (! buf.isEmpty()) emit audioBuffer(buf);
}

QList<double> WebAudioBridge::encodeBuffer(wallpaper::audio::AudioAnalyzer& analyzer) {
    if (! analyzer.HasData()) return {};

    auto leftSpan  = analyzer.GetRawSpectrum(64, 0);
    auto rightSpan = analyzer.GetRawSpectrum(64, 1);
    if (leftSpan.size() != 64 || rightSpan.size() != 64) return {};

    QList<double> out;
    out.reserve(128);
    // Contiguous primitive storage — zero per-element QVariant boxing.
    for (float v : leftSpan) out.append(static_cast<double>(v));
    for (float v : rightSpan) out.append(static_cast<double>(v));
    return out;
}

bool WebAudioBridge::feedTestPcm(const QList<qreal>& interleavedStereo, int channels) {
    if (channels <= 0) channels = 2;
    if (! m_analyzer) m_analyzer = std::make_shared<wallpaper::audio::AudioAnalyzer>();

    std::vector<float> pcm;
    pcm.reserve(static_cast<size_t>(interleavedStereo.size()));
    for (qreal v : interleavedStereo) pcm.push_back(static_cast<float>(v));

    const uint32_t frameCount = static_cast<uint32_t>(pcm.size() / channels);
    m_analyzer->FeedPcm(pcm.data(), frameCount, static_cast<uint32_t>(channels));
    m_analyzer->Process();
    return m_analyzer->HasData();
}

void WebAudioBridge::runOneTick() { onTimerTick(); }

} // namespace wekde
