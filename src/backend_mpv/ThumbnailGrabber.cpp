#include "ThumbnailGrabber.hpp"
#include <QDebug>
#include <QFileInfo>
#include <mpv/client.h>

namespace wekde
{

struct ThumbnailGrabber::Impl {
    mpv_handle* mpv { nullptr };
    // Once-per-instance latch for ctor-failure qCritical lines so a repeated
    // construct/destruct loop (test harnesses, future per-grab Impls) doesn't
    // muzzle the next instance's log. Intentionally NOT process-global.
    bool m_ctorLogged { false };

    Impl() {
        // libmpv requires LC_NUMERIC=C — pinned process-wide at plugin
        // startup in plugin.cpp's registerTypes (idempotent and held for the
        // plasmashell lifetime).  Re-applying here would mutate process-global
        // locale state from a QThreadPool worker, which is UB by the C
        // standard (std::setlocale is not thread-safe) even though glibc
        // appears stable in practice.
        mpv = mpv_create();
        if (! mpv) {
            qCritical() << "ThumbnailGrabber: mpv_create() returned null "
                           "— video thumbnail subsystem disabled";
            m_ctorLogged = true;
            return;
        }
        mpv_set_option_string(mpv, "vo", "null");
        mpv_set_option_string(mpv, "ao", "null");
        mpv_set_option_string(mpv, "audio", "no");
        mpv_set_option_string(mpv, "hwdec", "no");
        mpv_set_option_string(mpv, "input-default-bindings", "no");
        mpv_set_option_string(mpv, "input-vo-keyboard", "no");
        mpv_set_option_string(mpv, "screenshot-format", "jpg");
        mpv_set_option_string(mpv, "screenshot-jpeg-quality", "80");
        if (mpv_initialize(mpv) < 0) {
            qCritical() << "ThumbnailGrabber: mpv_initialize() failed "
                           "— video thumbnail subsystem disabled";
            m_ctorLogged = true;
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
    if (! d->mpv) {
        qWarning() << "ThumbnailGrabber: mpv handle is null (ctor failed?) for" << videoPath;
        return false;
    }
    if (! QFileInfo::exists(videoPath)) {
        qWarning() << "ThumbnailGrabber: source file does not exist:" << videoPath;
        return false;
    }

    const QByteArray vp = videoPath.toUtf8();
    const QByteArray op = outPath.toUtf8();
    const QByteArray ts = QByteArray::number(atSeconds, 'f', 3);

    const char* loadcmd[] = { "loadfile", vp.constData(), "replace", nullptr };
    if (mpv_command(d->mpv, loadcmd) < 0) {
        qWarning() << "ThumbnailGrabber: loadfile mpv_command failed for" << videoPath;
        return false;
    }

    // Wait for file load (5 second budget).
    bool loaded = false;
    for (int i = 0; i < 50 && ! loaded; i++) {
        mpv_event* ev = mpv_wait_event(d->mpv, 0.1);
        if (ev->event_id == MPV_EVENT_FILE_LOADED)
            loaded = true;
        else if (ev->event_id == MPV_EVENT_END_FILE) {
            qWarning() << "ThumbnailGrabber: END_FILE during load "
                          "(unreadable codec/container?) for"
                       << videoPath;
            return false;
        }
    }
    if (! loaded) {
        qWarning() << "ThumbnailGrabber: load timeout (>5s) for" << videoPath;
        return false;
    }

    const char* seekcmd[] = { "seek", ts.constData(), "absolute", "exact", nullptr };
    if (mpv_command(d->mpv, seekcmd) < 0) {
        qWarning() << "ThumbnailGrabber: seek mpv_command failed for" << videoPath
                   << "at t=" << atSeconds;
        return false;
    }

    // Wait for seek to complete.
    bool seeked = false;
    for (int i = 0; i < 50 && ! seeked; i++) {
        mpv_event* ev = mpv_wait_event(d->mpv, 0.1);
        if (ev->event_id == MPV_EVENT_PLAYBACK_RESTART)
            seeked = true;
        else if (ev->event_id == MPV_EVENT_END_FILE) {
            qWarning() << "ThumbnailGrabber: END_FILE during seek for" << videoPath;
            return false;
        }
    }
    // Seek timed out without a PLAYBACK_RESTART — bail rather than screenshot a
    // wrong-position (typically t=0) frame and falsely report success.
    if (! seeked) {
        qWarning() << "ThumbnailGrabber: seek timeout (>5s, no PLAYBACK_RESTART) for" << videoPath;
        return false;
    }

    const char* shotcmd[] = { "screenshot-to-file", op.constData(), "video", nullptr };
    if (mpv_command(d->mpv, shotcmd) < 0) {
        qWarning() << "ThumbnailGrabber: screenshot-to-file mpv_command failed for" << videoPath
                   << "->" << outPath;
        return false;
    }

    const bool ok = QFileInfo::exists(outPath) && QFileInfo(outPath).size() > 0;
    if (! ok) {
        qWarning() << "ThumbnailGrabber: screenshot file missing or zero-size for" << videoPath
                   << "->" << outPath;
    }
    return ok;
}

} // namespace wekde
