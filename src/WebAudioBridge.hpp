#pragma once
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <memory>

namespace wallpaper::audio
{
class AudioAnalyzer;
class AudioCapture;
} // namespace wallpaper::audio

namespace wekde
{

// Forwards system audio (PulseAudio/PipeWire .monitor source) FFT spectrum
// into web wallpapers.  Web backends use QtWebEngine + QWebChannel and can't
// reach the scene-side AudioAnalyzer that scene wallpapers tap; this bridge
// runs an independent capture + analyzer pair while a web wallpaper is
// active, emitting a 128-element QVariantList (64 left bands followed by 64
// right bands, values 0..1) at ~30Hz.
//
// QtWebView.qml relays the signal through `webobj.sigAudio`, which the
// injected `wallpaperRegisterAudioListener` shim hands to the wallpaper.
class WebAudioBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(int intervalMs READ intervalMs WRITE setIntervalMs NOTIFY intervalMsChanged)

public:
    explicit WebAudioBridge(QObject* parent = nullptr);
    ~WebAudioBridge() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool e);

    int  intervalMs() const { return m_intervalMs; }
    void setIntervalMs(int ms);

    // Pure helper: convert an analyzer's spectrum into a flat QVariantList of
    // 128 doubles (64 left, 64 right). Returns empty list when !HasData()
    // or when the resolution cap doesn't match (defensive — analyzer
    // currently always emits 64).
    static QVariantList encodeBuffer(wallpaper::audio::AudioAnalyzer& analyzer);

    // Test hook: feed PCM samples into the underlying analyzer and run one
    // FFT pass.  Lazy-creates the analyzer if `enabled` is false so tests
    // never need to flip the capture lifecycle on.
    Q_INVOKABLE bool feedTestPcm(const QList<qreal>& interleavedStereo, int channels = 2);

    // Test hook: synchronously do what the QTimer would do — Process the
    // analyzer and emit `audioBuffer` if data is available.  Production
    // code uses the timer; tests bypass it for determinism.
    Q_INVOKABLE void runOneTick();

signals:
    void enabledChanged();
    void intervalMsChanged();
    void audioBuffer(const QVariantList& samples);

private:
    void start();
    void stop();
    void onTimerTick();

    bool m_enabled { false };
    int  m_intervalMs { 33 };

    std::shared_ptr<wallpaper::audio::AudioAnalyzer> m_analyzer;
    std::unique_ptr<wallpaper::audio::AudioCapture>  m_capture;
    QTimer                                           m_timer;
};

} // namespace wekde
