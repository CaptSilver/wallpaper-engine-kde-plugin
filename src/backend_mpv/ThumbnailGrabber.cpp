#include "ThumbnailGrabber.hpp"
#include <QDebug>
#include <QFileInfo>
#include <mpv/client.h>

namespace wekde
{

struct ThumbnailGrabber::Impl {
    mpv_handle* mpv { nullptr };

    Impl() {
        // libmpv requires LC_NUMERIC=C — pinned process-wide at plugin
        // startup in plugin.cpp's registerTypes (idempotent and held for the
        // plasmashell lifetime).  Re-applying here would mutate process-global
        // locale state from a QThreadPool worker, which is UB by the C
        // standard (std::setlocale is not thread-safe) even though glibc
        // appears stable in practice.
        mpv = mpv_create();
        if (! mpv) return;
        mpv_set_option_string(mpv, "vo", "null");
        mpv_set_option_string(mpv, "ao", "null");
        mpv_set_option_string(mpv, "audio", "no");
        mpv_set_option_string(mpv, "hwdec", "no");
        mpv_set_option_string(mpv, "input-default-bindings", "no");
        mpv_set_option_string(mpv, "input-vo-keyboard", "no");
        mpv_set_option_string(mpv, "screenshot-format", "jpg");
        mpv_set_option_string(mpv, "screenshot-jpeg-quality", "80");
        if (mpv_initialize(mpv) < 0) {
            mpv_destroy(mpv);
            mpv = nullptr;
        }
    }
    ~Impl() {
        if (mpv) mpv_terminate_destroy(mpv);
    }
};

ThumbnailGrabber::ThumbnailGrabber(): d(std::make_unique<Impl>()) {}
ThumbnailGrabber::~ThumbnailGrabber() = default;

bool ThumbnailGrabber::grab(const QString& videoPath, const QString& outPath, double atSeconds) {
    if (! d->mpv) return false;
    if (! QFileInfo::exists(videoPath)) return false;

    const QByteArray vp = videoPath.toUtf8();
    const QByteArray op = outPath.toUtf8();
    const QByteArray ts = QByteArray::number(atSeconds, 'f', 3);

    const char* loadcmd[] = { "loadfile", vp.constData(), "replace", nullptr };
    if (mpv_command(d->mpv, loadcmd) < 0) return false;

    // Wait for file load (5 second budget).
    bool loaded = false;
    for (int i = 0; i < 50 && ! loaded; i++) {
        mpv_event* ev = mpv_wait_event(d->mpv, 0.1);
        if (ev->event_id == MPV_EVENT_FILE_LOADED)
            loaded = true;
        else if (ev->event_id == MPV_EVENT_END_FILE)
            return false;
    }
    if (! loaded) return false;

    const char* seekcmd[] = { "seek", ts.constData(), "absolute", "exact", nullptr };
    if (mpv_command(d->mpv, seekcmd) < 0) return false;

    // Wait for seek to complete.
    bool seeked = false;
    for (int i = 0; i < 50 && ! seeked; i++) {
        mpv_event* ev = mpv_wait_event(d->mpv, 0.1);
        if (ev->event_id == MPV_EVENT_PLAYBACK_RESTART)
            seeked = true;
        else if (ev->event_id == MPV_EVENT_END_FILE)
            return false;
    }
    // Seek timed out without a PLAYBACK_RESTART — bail rather than screenshot a
    // wrong-position (typically t=0) frame and falsely report success.
    if (! seeked) return false;

    const char* shotcmd[] = { "screenshot-to-file", op.constData(), "video", nullptr };
    if (mpv_command(d->mpv, shotcmd) < 0) return false;

    return QFileInfo::exists(outPath) && QFileInfo(outPath).size() > 0;
}

} // namespace wekde
