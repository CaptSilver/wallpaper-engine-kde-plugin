#include "WebAudioBridge.hpp"

#include "Audio/AudioAnalyzer.h"
#include "Audio/AudioCapture.h"

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
    m_analyzer = std::make_shared<wallpaper::audio::AudioAnalyzer>();
    m_capture  = std::make_unique<wallpaper::audio::AudioCapture>();

    if (! m_capture->Init(m_analyzer)) {
        // No .monitor source available (or PulseAudio/PipeWire missing).
        // Keep analyzer alive so test hooks still function, but don't
        // burn CPU running an FFT timer over silence.
        qWarning() << "WebAudioBridge: system audio capture unavailable; "
                      "audio-reactive web wallpapers will receive no spectrum data";
        m_capture.reset();
        m_timer.stop();
        return;
    }

    m_timer.start();
}

void WebAudioBridge::stop() {
    m_timer.stop();
    if (m_capture) m_capture->Stop();
    m_capture.reset();
    m_analyzer.reset();
}

void WebAudioBridge::onTimerTick() {
    if (! m_analyzer) return;
    m_analyzer->Process();
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
